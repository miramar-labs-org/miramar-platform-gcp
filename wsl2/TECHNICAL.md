# WSL2 Technical Model

This document is the source of truth for how WSL2 distros are provisioned and
reached from Spark and Orin. It captures the final SSH model, the WSL lifecycle
behavior that drove it, and the constraints that should be preserved when
changing `wsl2/` or `.github/workflows/*wsl2*`.

## Summary

WSL2 distros are on-demand endpoints, not always-on lab servers. Spark and Orin
connect to them through Windows OpenSSH, and each SSH session starts the target
distro with `wsl.exe` before handing the SSH byte stream to `sshd -i` inside
the distro.

The model intentionally avoids resident keepalive processes. WSL keeps a distro
running while a Windows-side `wsl.exe` client is attached; when no such client
exists, WSL can power the distro down even if systemd services such as `sshd` or
Docker are active.

## Root Cause

After provisioning, fresh WSL2 distros sometimes moved from `Running` to
`Stopped` even though `systemd`, `sshd`, and Docker were healthy during the
provision workflow. The important logs were:

```text
Operation canceled @p9io.cpp:258 (AcceptAsync)
systemd-logind: System is powering down.
```

Two tests isolated the behavior:

- With a Windows-side `wsl.exe` client attached, the distro remained `Running`.
- With no Windows-side client attached, the distro powered down after an idle
  window.

That means a Linux daemon inside WSL2 is not enough to make the distro a stable
resident SSH server. The stable primitive is a per-session Windows `wsl.exe`
client attachment.

## Architecture

Spark and Orin are the durable SSH control plane. WSL2 distros are activated
only when a supported SSH path needs them.

Supported paths:

```text
spark -> orin
orin  -> spark

spark -> wsl2-<name>
orin  -> wsl2-<name>

wsl2-<name> -> spark
wsl2-<name> -> orin
```

Unsupported CI path:

```text
wsl2-<name-a> -> wsl2-<name-b>
```

WSL2-to-WSL2 may work manually through direct mirrored-network ports if both
distros are already being held open by separate PowerShell `wsl -d <name>`
sessions, but that is not the repository topology. The shared `wsl2-<name>`
aliases use nested on-demand `ProxyCommand` sessions, and those are not treated
as a supported WSL2 peer mesh.

## On-Demand ProxyCommand

The shared SSH config contains one alias per distro:

```sshconfig
Host wsl2-dev
    HostName wsl2-dev
    User aaron
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ProxyCommand ssh -q -i /home/aaron/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new aaron@msi.local "wsl -d dev --user root --exec /bin/bash -lc \"/usr/local/sbin/mount-dgx-shared.sh >/dev/null 2>&1 || true; exec /usr/sbin/sshd -i -e\""
```

Connection flow:

1. The local SSH client on Spark or Orin invokes the `ProxyCommand`.
2. The proxy SSHes to the Windows host on port `22`.
3. Windows runs `wsl -d <name> --user root --exec /bin/bash -lc ...`.
4. The distro mounts the shared store if needed.
5. The distro execs `/usr/sbin/sshd -i -e`.
6. The outer SSH client authenticates against that inetd-mode `sshd`.

`sshd -i` uses stdin/stdout as the SSH transport. For that reason, helper output
must not be written to stdout. The mount helper is redirected to `/dev/null`;
only the SSH protocol is allowed on the ProxyCommand stdout stream.

## Shared SSH Store

The SSH topology is shared across Spark, Orin, and WSL2 through:

```text
/home/aaron/shared/ssh
```

Important files:

```text
/home/aaron/shared/ssh/config
/home/aaron/shared/ssh/known_hosts
/home/aaron/shared/ssh/authorized_keys
/home/aaron/shared/ssh/id_ed25519
/home/aaron/shared/ssh/id_ed25519.pub
```

Inside provisioned WSL2 distros, `/home/aaron/.ssh/*` is symlinked to the shared
store. In particular:

```text
/home/aaron/.ssh/authorized_keys -> /home/aaron/shared/ssh/authorized_keys
```

This is intentional. Do not replace it with a local per-distro
`authorized_keys` file. Spark, Orin, and WSL2 must keep one shared SSH identity
and one shared authorization store.

## Mount Before sshd

Cold WSL starts can enter the ProxyCommand before `/home/aaron/shared` is
mounted. If `sshd -i` starts before the shared store is mounted, public-key
authentication fails because `/home/aaron/.ssh/authorized_keys` points at a
missing target.

The fix is to mount the shared store inside the on-demand ProxyCommand before
execing `sshd`:

```sh
/usr/local/sbin/mount-dgx-shared.sh >/dev/null 2>&1 || true
exec /usr/sbin/sshd -i -e
```

The `|| true` keeps the proxy command from failing before `sshd` can report the
real authentication result. A failed mount still means the shared
`authorized_keys` file is unavailable, so authentication fails closed. There is
no local authorization fallback.

## Ports

Each distro still has a unique direct `sshd` port for provisioning readiness
checks and manual diagnostics:

```text
dev  -> 2222
test -> 2223
```

Additional distros should increment from there. The port is configured during
`WSL2 Provision` and should not be reused by another active distro.

The direct port is not the primary SSH path from Spark or Orin. Normal SSH uses
the `wsl2-<name>` alias and the on-demand ProxyCommand through Windows port
`22`.

Before choosing a new port, probe the candidate range from Windows PowerShell:

```powershell
cd path\to\miramar-platform-gcp\wsl2
.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299
```

The script reports contiguous OK ranges after checking Windows-visible listeners,
Windows excluded TCP ranges, and real `sshd` bindability inside the selected WSL
distro. The selected distro must already exist and have `/usr/sbin/sshd`.

## Workflow Responsibilities

`WSL2 Provision`:

- Imports a distro from `C:\wsl-templates\ubuntu-22.04-configured-template.tar`.
- Writes `/etc/wsl2-provision.conf`.
- Runs `firstboot.sh` inside the distro through Windows SSH and `wsl.exe`.
- Configures hostname, direct sshd port, post-boot shared mount timer, and SSH
  symlinks.
- Writes the `wsl2-<name>` alias into the shared SSH config.
- Adds the distro to the `WSL2_DISTROS` repo variable.
- Calls `WSL2 Verify SSH Topology`.

`WSL2 Verify SSH Topology`:

- Reads active distros from `WSL2_DISTROS`, unless a `distros` input overrides
  that list.
- Tests Spark/Orin core reachability.
- Tests Spark/Orin to each active WSL2 distro.
- Tests each WSL2 distro back to Spark and Orin.
- Does not test WSL2-to-WSL2 peer paths.

`WSL2 Unprovision`:

- Unregisters a distro from WSL.
- Optionally deletes `C:\wsl\<name>`.
- Removes the distro from `WSL2_DISTROS`, setting the variable to `NONE` when no
  distros remain.

## Template and Mounting Rules

The configured template should not contain a live CIFS mount in `/etc/fstab`.
WSL2 provisioning keeps:

```ini
[automount]
mountFsTab=false
```

The shared store is mounted after boot by `mount-dgx-shared.service` /
`mount-dgx-shared.timer`, and on demand by the SSH ProxyCommand. This avoids
boot-time CIFS and Plan 9 interactions that can contribute to WSL shutdowns.

`rebuild-template.ps1` removes stale shared-folder fstab entries and keeps the
Samba credentials baked into the template at:

```text
/home/aaron/.smbcredentials
```

## Windows Host Prerequisites

The GitHub Actions workflows SSH to the Windows host first, then run `wsl.exe`
from that Windows session. The Windows host needs OpenSSH Server, PowerShell as
the default SSH shell, mirrored WSL networking, and Spark's public key
authorized for the Windows user.

Enable OpenSSH Server from Windows Settings, then start it from PowerShell:

```powershell
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Set PowerShell as the default OpenSSH shell:

```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
  -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -PropertyType String -Force
```

Authorize Spark's public key (`/home/aaron/shared/ssh/id_ed25519.pub` on the
DGX) for the Windows user. For an admin user, add it to:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

Then fix Windows OpenSSH permissions:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "Administrators:F"
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "SYSTEM:F"
Restart-Service sshd
```

For non-admin users, use:

```text
C:\Users\<user>\.ssh\authorized_keys
```

Enable mirrored networking in `$env:USERPROFILE\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
firewall=true
```

Do not include `localhostForwarding=true`; it has no effect in mirrored mode
and causes a warning. Restart WSL after changing `.wslconfig`:

```powershell
wsl --shutdown
wsl
```

## Rebuild the Configured Template

Use `rebuild-template.ps1` when `bootstrap.sh` changes, when rotating the Samba
password, or when refreshing tools already present in the configured template.
It starts from the existing configured tarball, so no clean Ubuntu install is
needed.

Run from Windows PowerShell:

```powershell
cd path\to\miramar-platform-gcp\wsl2
.\rebuild-template.ps1 -SmbPassword <samba-password>
```

The script:

1. Imports the current tarball as a temp distro named `template-build`.
2. Writes `/home/aaron/.smbcredentials` for the Samba share.
3. Removes legacy shared-folder CIFS entries from `/etc/fstab`.
4. Keeps `mountFsTab = false`.
5. Exports back to the same tar path and backs up the old tar as `-prev.tar`.
6. Cleans up the temp distro.

Optional parameters:

```text
-DistroUser  default: aaron
-TarPath     default: C:\wsl-templates\ubuntu-22.04-configured-template.tar
-BuildName   default: template-build
-BuildDir    default: C:\wsl\template-build
```

After rebuilding, validate with:

```text
Actions -> Setup Shared SSH Store
Actions -> WSL2 Provision -> distro_name: test  ssh_port: 2223
Actions -> WSL2 Verify SSH Topology
```

## Build a Configured Template From Scratch

Only use this path when there is no existing configured tarball or a completely
clean base is desired.

Install Ubuntu 22.04:

```powershell
wsl --update
wsl --install -d Ubuntu-22.04
```

For NVIDIA containers, install a current NVIDIA Windows driver with WSL2 CUDA
support. Do not install a Linux display driver inside WSL. After the driver is
installed, `nvidia-smi` should eventually work inside WSL.

Enable passwordless sudo inside the distro:

```bash
sudo visudo -f /etc/sudoers.d/aaron
```

Add:

```text
aaron ALL=(ALL) NOPASSWD: ALL
```

Create `/etc/wsl.conf`:

```ini
[boot]
systemd=true

[user]
default=aaron

[interop]
appendWindowsPath=false
```

Export a base snapshot from PowerShell:

```powershell
wsl --shutdown
mkdir C:\wsl-templates -Force
wsl --export Ubuntu-22.04 C:\wsl-templates\ubuntu-22.04-base-template.tar
```

Import the base and enter it:

```powershell
mkdir C:\wsl\Ubuntu2204-Base -Force
wsl --import Ubuntu2204-Base C:\wsl\Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-base-template.tar --version 2
wsl -d Ubuntu2204-Base --cd ~
```

Inside the distro, download and run the bootstrap files:

```bash
curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/mount-dgx-shared.sh -o mount-dgx-shared.sh
chmod +x mount-dgx-shared.sh

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/mount-dgx-shared.service -o mount-dgx-shared.service

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/mount-dgx-shared.timer -o mount-dgx-shared.timer

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/setup-shared-ssh.sh -o setup-shared-ssh.sh
chmod +x setup-shared-ssh.sh

DGX_SMB_PASSWORD=<samba-password> DGX_PUBKEY="$(ssh 192.168.1.200 cat /home/aaron/.ssh/id_ed25519.pub)" ./bootstrap.sh
```

After optional shell customization, shut down and export the configured
template:

```powershell
wsl --shutdown
mkdir C:\wsl-templates -Force
wsl --export Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-configured-template.tar
wsl --unregister Ubuntu2204-Base
wsl --unregister Ubuntu-22.04
```

Then wire the shared SSH store and validate:

```text
Actions -> Setup Shared SSH Store
Actions -> WSL2 Provision -> distro_name: test
Actions -> WSL2 Verify SSH Topology
```

## Manual Distro Bring-Up

GitHub Actions is the normal path. For diagnostics, a distro can be imported and
bootstrapped manually from PowerShell:

```powershell
wsl --import Ubuntu2204-Dev1 C:\wsl\Ubuntu2204-Dev1 C:\wsl-templates\ubuntu-22.04-configured-template.tar --version 2
```

Write `/etc/wsl2-provision.conf` before running `firstboot.sh`:

```powershell
wsl -d Ubuntu2204-Dev1 --user root -- bash -c "echo distro_name=dev > /etc/wsl2-provision.conf && echo ssh_port=2222 >> /etc/wsl2-provision.conf && echo mount_user=aaron >> /etc/wsl2-provision.conf && echo dgx_host_ip=192.0.2.10 >> /etc/wsl2-provision.conf"
wsl -d Ubuntu2204-Dev1 --user root -- bash /usr/local/bin/firstboot.sh
```

## Operational Notes

Seeing `dev` or `test` in `Stopped` state after provision is not by itself a
failure. It means no Windows-side WSL client is attached. The next supported SSH
connection through `wsl2-dev` or `wsl2-test` should start the distro on demand.

If `test` waits on port `2222`, the workflow was launched with the wrong port.
Use:

```text
dev  ssh_port: 2222
test ssh_port: 2223
```

If a cold WSL start fails with:

```text
Permission denied (publickey,password)
```

check whether `/home/aaron/shared/ssh` was mounted before `sshd` performed
public-key authentication. The expected fix is in the ProxyCommand mount step,
not a local `authorized_keys` file.

If a WSL2-to-WSL2 check fails with:

```text
banner exchange: Connection to UNKNOWN port 65535: Broken pipe
```

that is the unsupported nested peer path. Do not add that path back to CI.

## Standard Validation Sequence

For a clean two-distro validation:

```text
Actions -> WSL2 Unprovision -> distro_name: test
Actions -> WSL2 Unprovision -> distro_name: dev

Actions -> WSL2 Provision   -> distro_name: dev   ssh_port: 2222
Actions -> WSL2 Provision   -> distro_name: test  ssh_port: 2223

Actions -> WSL2 Verify SSH Topology
```

The final verify workflow should pass all supported Spark, Orin, and WSL2 edge
paths. It should not include WSL2-to-WSL2 peer checks.

## Non-Goals

Do not add these back:

- Resident WSL keepalive services or background loops.
- Per-distro local `authorized_keys` files.
- CIFS shared-store mounts from `/etc/fstab` at WSL boot.
- WSL2-to-WSL2 peer checks in CI.
- Shared port `2222` for more than one active distro.
