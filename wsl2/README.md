# WSL2 Dev Environments

## GHA Workflows

Provision and unprovision WSL2 distros from the configured template tarball via GitHub Actions.

| Workflow                                                  | Purpose                                                                                                                                                                                                                                        |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **WSL2 Provision** (`provision-wsl2.yaml`)                | Import a new distro from `C:\wsl-templates\ubuntu-22.04-configured-template.tar`, run `firstboot.sh` inside the distro via `wsl exec` (sets hostname, sshd port, post-boot CIFS timer, SSH symlinks), authorize DGX key, verify sshd + systemd |
| **WSL2 Verify SSH Topology** (`verify-ssh-topology.yaml`) | Validate bi-directional SSH across all lab nodes. Reads active distros from `WSL2_DISTROS` and tests spark↔orin, spark↔wsl2-`<name>`, orin↔wsl2-`<name>`, and wsl2-`<A>`↔wsl2-`<B>` for all pairs. No inputs required.                         |
| **WSL2 Unprovision** (`unprovision-wsl2.yaml`)            | Unregister a distro; optionally delete the folder at `C:\wsl\<name>`                                                                                                                                                                           |

### WSL2 lifecycle model

WSL2 distros are treated as on-demand environments, not always-on servers. Root-cause
diagnostics showed that after provision, WSL powers down a distro when there is no
Windows-side `wsl.exe` client attached, even if systemd services such as sshd and Docker
are running. The shutdown is logged as `Operation canceled @p9io.cpp:258 (AcceptAsync)`
followed by `systemd-logind: System is powering down`.

The shared `wsl2-<name>` SSH alias therefore connects through the Windows host and runs
`wsl.exe -d <name> --user root --exec /usr/sbin/sshd -i -e` for each SSH session. This
creates a per-session WSL client attachment without a resident keepalive process.

Normal provisioning sequence:

```
Actions → WSL2 Provision           → distro_name: dev
Actions → WSL2 Verify SSH Topology   (no inputs — reads WSL2_DISTROS automatically)
```

Teardown:

```
Actions → WSL2 Unprovision → distro_name: dev  delete_files: false
```

The provision workflow SSHes to the **Windows host** (not the distro directly) and runs all
per-distro config via `wsl -d NAME --user root -- bash`. This avoids WSL2 mirrored-networking
issues that cause TCP connection drops when restarting sshd or changing hostnames via direct
port-2222 SSH.

### Prerequisites

**1. Enable OpenSSH Server on Windows**

Settings → System → Optional features → Add a feature → OpenSSH Server, then:

```powershell
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

**2. Set PowerShell as the default SSH shell** (so commands are interpreted correctly):

```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
  -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -PropertyType String -Force
```

**3. Authorize the SSH key for the Windows user**

Add Spark's public key (`/home/aaron/shared/ssh/id_ed25519.pub` on the DGX) to
`C:\ProgramData\ssh\administrators_authorized_keys` (for admin users) or
`C:\Users\<user>\.ssh\authorized_keys`. All distros share Spark's SSH identity — no
per-distro keypair. Fix permissions after editing (required by Windows OpenSSH):

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "Administrators:F"
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "SYSTEM:F"
Restart-Service sshd
```

See [ssh-win.md](ssh-win.md) for details.

**4. Enable mirrored networking** (`.wslconfig`)

On Windows PowerShell (no elevation needed), create or edit `$env:USERPROFILE\.wslconfig`:

```powershell
notepad $env:USERPROFILE\.wslconfig
```

Contents:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
firewall=true
```

> Do not include `localhostForwarding=true` — it has no effect in mirrored mode and causes a warning.

Then restart WSL:

```powershell
wsl --shutdown
wsl
```

**5. Build the template tarball** (one-time, or after `bootstrap.sh` changes).
See [Rebuild the configured template](#rebuild-the-configured-template) below.

**6. Set GitHub secrets and vars** (repo or org level):

| Secret / Var                 | Value                                                                    | Used by                                                                               |
| ---------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| `WSL2_HOST` (secret)         | Windows hostname or IP (e.g. `msi.local`)                                | provision, verify, unprovision                                                        |
| `WSL2_HOST_USER` (secret)    | Windows SSH username                                                     | provision, verify, unprovision                                                        |
| `WSL2_HOST_SSH_KEY` (secret) | Private key authorized on Windows                                        | provision, verify, unprovision                                                        |
| `DGX_HOST_SSH_KEY` (secret)  | Spark's private key — used to authorize DGX in the distro and verify SSH | provision, verify                                                                     |
| `DGX_HOST_IP` (var)          | DGX static IP for SSH and CIFS (avoid mDNS `.local`)                     | provision, setup, deploy workflows                                                    |
| `DGX_HOST_USER` (var)        | DGX / Samba username                                                     | provision                                                                             |
| `WSL2_DISTROS` (repo var)    | `NONE` initially                                                         | Tracks active distro names — create once with value `NONE` before first provision run |

`DGX_SMB_PASSWORD` is **not** required by the provision workflow — credentials are baked into
the template by `rebuild-template.ps1`.

---

# Manual Setup

## Rebuild the configured template

Use this when `bootstrap.sh` has changed (new tools, rotated Samba password) and you need to
bake the updates into the tarball. Starts from the **existing** tarball — no fresh install needed.

On **Windows PowerShell** (no elevation required):

```powershell
cd path\to\miramar-platform-gcp\wsl2
.\rebuild-template.ps1 -SmbPassword <samba-password>
```

This script:

1. Imports the current tarball as a temp distro (`template-build`)
2. Writes `/home/aaron/.smbcredentials` for the Samba share
3. Removes legacy shared-folder CIFS entries from `/etc/fstab` and keeps `mountFsTab = false`
4. Exports back to the same tar path (backs up old tar as `-prev.tar`)
5. Cleans up the temp distro

Do not mount the DGX shared folder from `/etc/fstab` inside WSL2. WSL pre-systemd
fstab handling plus mDNS/CIFS can delay boot or disrupt Plan 9/p9io, causing
`AcceptAsync` cancellation followed by distro powerdown. The distro uses
`mount-dgx-shared.service` and `mount-dgx-shared.timer` after boot instead.

Optional parameters: `-DistroUser` (default `aaron`), `-TarPath`, `-BuildName`, `-BuildDir`.

After rebuilding, verify the template works:

```
Actions → WSL2 Provision           → distro_name: test
Actions → WSL2 Verify SSH Topology   (no inputs — reads WSL2_DISTROS automatically)
```

---

## Build a configured template from scratch

Only needed if there is no existing tarball, or you want a completely clean base.

### Install Ubuntu 22.04

```powershell
wsl --update
wsl --install -d Ubuntu-22.04
```

### GPU (only if you want NVIDIA containers)

Install the latest NVIDIA Windows driver that supports WSL2 CUDA. NVIDIA's WSL guide
emphasizes: install the Windows driver only (don't install a Linux display driver inside WSL).
[NVIDIA Docs](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)

After driver install, inside WSL you should eventually be able to run:

    nvidia-smi

### Enable passwordless sudo in distro

    sudo visudo -f /etc/sudoers.d/aaron

Add:

    aaron ALL=(ALL) NOPASSWD: ALL

Create `/etc/wsl.conf`:

    [boot]
    systemd=true
    [user]
    default=aaron
    [interop]
    appendWindowsPath=false

### Export a base snapshot (PowerShell)

    wsl --shutdown
    mkdir C:\wsl-templates -Force
    wsl --export Ubuntu-22.04 C:\wsl-templates\ubuntu-22.04-base-template.tar

### Import and run bootstrap.sh

    mkdir C:\wsl\Ubuntu2204-Base -Force
    wsl --import Ubuntu2204-Base C:\wsl\Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-base-template.tar --version 2
    wsl -d Ubuntu2204-Base --cd ~

Inside the distro, pull and run bootstrap.sh:

```bash
curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/mount-dgx-shared.sh -o mount-dgx-shared.sh
chmod +x mount-dgx-shared.sh

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/mount-dgx-shared.service -o mount-dgx-shared.service
#chmod +x mount-dgx-shared.service

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/mount-dgx-shared.timer -o mount-dgx-shared.timer
#chmod +x mount-dgx-shared.timer

curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/setup-shared-ssh.sh -o setup-shared-ssh.sh
chmod +x setup-shared-ssh.sh

DGX_SMB_PASSWORD=<samba-password> DGX_PUBKEY="$(ssh 192.168.1.200 cat ~/.ssh/id_ed25519.pub)" ./bootstrap.sh
```

Configure p10k if desired, then:

```powershell
wsl --shutdown
```

### Export the configured template (PowerShell)

```powershell
mkdir C:\wsl-templates -Force
wsl --export Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-configured-template.tar
wsl --unregister Ubuntu2204-Base
wsl --unregister Ubuntu-22.04
```

### Wire the shared SSH store

```
Actions → Setup Shared SSH Store
Actions → WSL2 Provision           → distro_name: test
Actions → WSL2 Verify SSH Topology → distro_name: test
```

---

## Bring up a distro manually (without GHA)

```powershell
wsl --import Ubuntu2204-Dev1 C:\wsl\Ubuntu2204-Dev1 C:\wsl-templates\ubuntu-22.04-configured-template.tar --version 2
```

Then run `firstboot.sh` manually (requires `/etc/wsl2-provision.conf` to exist first):

```powershell
# Write the provision config
wsl -d Ubuntu2204-Dev1 --user root -- bash -c "echo distro_name=dev > /etc/wsl2-provision.conf && echo ssh_port=2222 >> /etc/wsl2-provision.conf && echo mount_user=aaron >> /etc/wsl2-provision.conf && echo dgx_host_ip=192.0.2.10 >> /etc/wsl2-provision.conf"
# Run firstboot
wsl -d Ubuntu2204-Dev1 --user root -- bash /usr/local/bin/firstboot.sh
```

---

## Validation

After provisioning, verify all SSH paths:

| From | Command                 | Expected                       |
| ---- | ----------------------- | ------------------------------ |
| WSL2 | `ssh orin hostname`     | `orin`                         |
| WSL2 | `ssh spark hostname`    | `spark-79b7` (or DGX hostname) |
| DGX  | `ssh wsl2-dev hostname` | `dev`                          |
| Orin | `ssh wsl2-dev hostname` | `dev`                          |

BatchMode test (confirms no password fallback):

```bash
ssh -o BatchMode=yes wsl2-dev hostname
```

Or run **WSL2 Verify SSH Topology** to check all paths automatically.

Full topology details and troubleshooting: [docs/ssh-runbook.md](../docs/ssh-runbook.md)
