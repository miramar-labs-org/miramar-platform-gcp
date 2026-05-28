# SSH Runbook: DGX, Orin, MSI, and WSL2

> **Most of this is automated.** Spark's `/home/aaron/shared/ssh/` is the canonical SSH store. All machines mount it via CIFS and symlink `/home/aaron/.ssh/` to it — sharing Spark's SSH identity. GHA workflows manage it:
>
> | Workflow                     | What it does                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
> | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
> | **Setup Shared SSH Store**   | One-time: init `/home/aaron/shared/ssh/` on Spark (including `id_ed25519` + `id_ed25519.pub`), create `/home/aaron/.ssh/` symlinks on Spark, and wire Orin: CIFS-mount Spark's share at `/home/aaron/shared/`, symlink all `/home/aaron/.ssh/` files to `/home/aaron/shared/ssh/` (Orin uses Spark's identity — no local keypair). SSHes to Orin via `localhost:22` from agx runner. Secrets: `DGX_HOST_SSH_KEY`, `ORIN_HOST_SSH_KEY`, `DGX_SMB_PASSWORD`. |
> | **WSL2 Provision**           | Per-distro: SSHes to the Windows host and runs all config via `wsl -d NAME --user root` (wsl exec) — **no direct port-2222 SSH into the distro**. Writes `/etc/wsl2-provision.conf`, opens Windows Firewall, runs `firstboot.sh` (hostname, sshd port via systemd, post-boot CIFS mount, SSH symlinks, `wsl2-<name>` host block). `.smbcredentials` is baked into the template by `rebuild-template.ps1`. Secrets: `WSL2_HOST`, `WSL2_HOST_USER`, `WSL2_HOST_SSH_KEY`, `DGX_HOST_SSH_KEY`. |
> | **WSL2 Verify SSH Topology** | Validate supported SSH paths. Reads active distros from `WSL2_DISTROS` and tests spark/orin core reachability, spark/orin to each `wsl2-<name>`, and each `wsl2-<name>` back to spark/orin. WSL2-to-WSL2 peer paths are intentionally excluded. Reports pass/fail per path. Triggered manually or called from WSL2 Provision. |
>
> **Orin one-time prerequisites** (run on Orin host as `aaron` before first Setup Shared SSH Store run):
>
> ```bash
> # Restore SSH files if only .bak files exist (left by old CIFS setup):
> cp /home/aaron/.ssh/authorized_keys.bak /home/aaron/.ssh/authorized_keys 2>/dev/null || touch /home/aaron/.ssh/authorized_keys
> cp /home/aaron/.ssh/config.bak /home/aaron/.ssh/config 2>/dev/null || true
> cp /home/aaron/.ssh/known_hosts.bak /home/aaron/.ssh/known_hosts 2>/dev/null || true
> chmod 600 /home/aaron/.ssh/authorized_keys /home/aaron/.ssh/config /home/aaron/.ssh/known_hosts 2>/dev/null || true
> # Self-authorize Orin's own key so ORIN_HOST_SSH_KEY can SSH to localhost:
> grep -qF "$(cat /home/aaron/.ssh/id_ed25519.pub)" /home/aaron/.ssh/authorized_keys \
>   || cat /home/aaron/.ssh/id_ed25519.pub >> /home/aaron/.ssh/authorized_keys
> # Add Orin's private key as ORIN_HOST_SSH_KEY GitHub secret:
> cat /home/aaron/.ssh/id_ed25519
> ```
>
> The manual steps below are kept as a **legacy direct-port reference and troubleshooting fallback** only. They are not the normal setup path for current WSL2 distros. For normal operation, use [../wsl2/README.md](../wsl2/README.md). For the current WSL2 lifecycle, template build procedures, and on-demand SSH design, read [../wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md) first.

---

This runbook documents the current SSH topology for a local lab consisting of:

| Machine            | Hostname        | DNS                | SSH alias                              |
| ------------------ | --------------- | ------------------ | -------------------------------------- |
| DGX / Spark        | `spark-79b7`    | `spark-79b7.local` | `spark` / `dgx`                        |
| Jetson Orin        | `orin`          | `orin.local`       | `orin`                                 |
| MSI Windows laptop | `msi`           | `msi.local`        | `msi` (Windows shell, port 22)         |
| WSL2 distro on MSI | `<distro_name>` | —                  | `wsl2-<distro_name>` (sshd port 2222+) |

Each WSL2 distro gets its own name and sshd port. The `wsl2-<name>` SSH alias is written
into the shared `/home/aaron/shared/ssh/config` by `setup-shared-ssh.sh` during provisioning and is
immediately visible on all machines that share the store.

All machines share Spark's `id_ed25519` identity — there are no per-machine keypairs.

---

## Final Topology

```text
ssh msi          -> MSI Windows OpenSSH shell on port 22
ssh wsl2-<name>  -> WSL2 distro Linux shell through on-demand Windows wsl.exe
ssh orin         -> Jetson Orin
ssh spark        -> DGX / Spark
```

Each WSL2 distro gets a unique alias (`wsl2-dev`, `wsl2-test`, etc.) and direct
sshd port (`2222`, `2223`, etc.). The `Host wsl2-<name>` block is written to the
shared SSH config by **WSL2 Provision** and picked up by all machines
automatically via the shared store.

Important distinction:

```text
MSI Windows OpenSSH uses port 22.
WSL2 direct sshd uses port 2222 for `dev`, 2223 for `test`, and higher ports for additional distros.
```

This avoids the problem where `ssh wsl2` accidentally lands in the MSI Windows shell.
Normal Spark/Orin access should use `ssh wsl2-<name>`, which starts the distro on
demand through Windows OpenSSH and `wsl.exe`.

---

## Global Rules

1. Use `id_ed25519` keys only.
2. Do not use `~` in SSH config files.
3. Use absolute Linux key paths:

```text
/home/aaron/.ssh/id_ed25519
```

4. Use absolute Windows key paths:

```text
C:\Users\aaron\.ssh\id_ed25519
```

5. `msi` means MSI Windows OpenSSH on port `22`.
6. `wsl2-<name>` means an on-demand WSL2 Linux SSH session through Windows OpenSSH and `wsl.exe`.
7. Direct WSL2 sshd ports are for provisioning readiness checks and manual diagnostics.
8. The DGX host is `spark-79b7.local`; do not mistype it as `spar-79b7.local`.
9. Windows firewall changes require Administrator PowerShell.
10. If `ssh wsl2` opens the MSI Windows shell, the SSH client is hitting port `22`; use the generated `wsl2-<name>` alias.

---

## Legacy Direct-Port Reference

The remaining numbered setup parts document the older direct-port WSL2 SSH
model. Use them only for diagnostics or for reconstructing a broken host by
hand. Current provisioned distros should be managed by **WSL2 Provision** and
accessed with `wsl2-<name>` aliases, not a generic `wsl2` host block or local
per-distro keypairs.

## Assumptions For Legacy Sections

Update these if your LAN changes:

```text
User: aaron
WSL2 hostname: wsl2
WSL2 LAN IP: 192.168.1.201
WSL2 SSH port: 2222
MSI Windows SSH port: 22
DGX DNS name: spark-79b7.local
Orin DNS name: orin.local
MSI DNS name: msi.local
```

---

# Part 1: Windows WSL2 Global Networking

On the MSI Windows laptop, edit:

```powershell
notepad $env:USERPROFILE\.wslconfig
```

Use:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
firewall=true
```

Do **not** include this with mirrored networking:

```ini
localhostForwarding=true
```

It has no effect in mirrored mode and causes a warning.

Restart WSL from PowerShell:

```powershell
wsl --shutdown
wsl
```

---

# Part 2: WSL2 Instance Configuration

Inside WSL2, edit:

```bash
sudo nano /etc/wsl.conf
```

Use:

```ini
[boot]
systemd=true

[user]
default=aaron

[interop]
appendWindowsPath=false

[network]
hostname=wsl2
generateHosts=true
generateResolvConf=true
```

Restart WSL from Windows PowerShell:

```powershell
wsl --shutdown
wsl
```

Verify inside WSL2:

```bash
hostname
hostnamectl
```

Expected:

```text
wsl2
```

---

# Part 3: Verify WSL2 LAN Networking

Inside WSL2:

```bash
hostname -I
ip addr
cat /etc/resolv.conf
```

Expected: WSL2 should have a real LAN IP, for example:

```text
192.168.1.201
```

A DNS resolver like this is normal with WSL DNS tunneling:

```text
nameserver 10.255.255.254
```

---

# Part 4: Install Baseline Packages in WSL2

Inside WSL2:

```bash
sudo apt update
sudo apt upgrade -y

sudo apt install -y \
  git \
  curl \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  build-essential \
  unzip \
  zip \
  jq \
  yq \
  tree \
  htop \
  net-tools \
  dnsutils \
  iproute2 \
  iputils-ping \
  netcat-openbsd \
  openssh-client \
  openssh-server \
  avahi-daemon \
  libnss-mdns
```

Enable services:

```bash
sudo systemctl enable --now ssh
sudo systemctl enable --now avahi-daemon
```

Check status:

```bash
systemctl status ssh --no-pager
systemctl status avahi-daemon --no-pager
```

---

# Part 5: Configure WSL2 SSH Server on Port 2222

Inside WSL2:

```bash
echo 'Port 2222' | sudo tee /etc/ssh/sshd_config.d/wsl2-port.conf
sudo systemctl restart ssh
ss -tlnp | grep 2222
```

Expected:

```text
LISTEN 0      128           0.0.0.0:2222      0.0.0.0:*
LISTEN 0      128              [::]:2222         [::]:*
```

This means WSL2 sshd is listening on port `2222`.

---

# Part 6: Open Windows Firewall for WSL2 SSH Port 2222

This must be done from **Administrator PowerShell** on MSI Windows.

Open:

```text
Start -> PowerShell -> right-click -> Run as administrator
```

Run:

```powershell
New-NetFirewallRule `
  -DisplayName "WSL2 SSH 2222 Inbound" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 2222 `
  -Action Allow
```

Verify:

```powershell
Get-NetFirewallRule -DisplayName "WSL2 SSH 2222 Inbound"
```

---

# Part 7: Create or Verify WSL2 ED25519 Key

Inside WSL2:

```bash
mkdir -p /home/aaron/.ssh
chmod 700 /home/aaron/.ssh

test -f /home/aaron/.ssh/id_ed25519 || \
  ssh-keygen -t ed25519 -f /home/aaron/.ssh/id_ed25519 -C "aaron@wsl2"

chmod 600 /home/aaron/.ssh/id_ed25519
chmod 644 /home/aaron/.ssh/id_ed25519.pub
```

Print the WSL2 public key:

```bash
cat /home/aaron/.ssh/id_ed25519.pub
```

---

# Part 8: Prepare WSL2 authorized_keys

Inside WSL2:

```bash
mkdir -p /home/aaron/.ssh
touch /home/aaron/.ssh/authorized_keys
chmod 700 /home/aaron/.ssh
chmod 600 /home/aaron/.ssh/authorized_keys
chown -R aaron:aaron /home/aaron/.ssh
```

---

# Part 9: Add DGX and Orin Public Keys to WSL2

From each Linux machine that needs to SSH into WSL2, install its public key into WSL2.

From DGX:

```bash
ssh-copy-id -p 2222 -i /home/aaron/.ssh/id_ed25519.pub aaron@192.168.1.201
```

From Orin:

```bash
ssh-copy-id -p 2222 -i /home/aaron/.ssh/id_ed25519.pub aaron@192.168.1.201
```

Validate from DGX:

```bash
ssh -o BatchMode=yes -p 2222 -i /home/aaron/.ssh/id_ed25519 aaron@192.168.1.201 hostname
```

Expected:

```text
wsl2
```

Validate from Orin:

```bash
ssh -o BatchMode=yes -p 2222 -i /home/aaron/.ssh/id_ed25519 aaron@192.168.1.201 hostname
```

Expected:

```text
wsl2
```

If WSL2 prompts for a password, check that `/home/aaron/.ssh/authorized_keys` contains the client public key.

---

# Part 10: Add WSL2 Public Key to Orin and DGX

From WSL2, install the WSL2 public key onto Orin:

```bash
ssh-copy-id -i /home/aaron/.ssh/id_ed25519.pub aaron@orin.local
```

Install the WSL2 public key onto DGX / Spark:

```bash
ssh-copy-id -i /home/aaron/.ssh/id_ed25519.pub aaron@spark-79b7.local
```

Test from WSL2:

```bash
ssh orin hostname
ssh spark hostname
```

---

# Part 11: Add WSL2 Public Key to MSI Windows Admin Authorized Keys

Use this when the Windows user `aaron` is a member of the local Administrators group.

Windows OpenSSH may use this file instead of `C:\Users\aaron\.ssh\authorized_keys`:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

Inside WSL2, print the WSL2 public key:

```bash
cat /home/aaron/.ssh/id_ed25519.pub
```

On MSI Windows, open **Administrator PowerShell** and edit:

```powershell
notepad C:\ProgramData\ssh\administrators_authorized_keys
```

Paste the WSL2 public key as one complete line.

Then fix permissions from Administrator PowerShell:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "Administrators:F"
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "SYSTEM:F"
Restart-Service sshd
```

Verify permissions:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys
```

Expected permissions should include:

```text
BUILTIN\Administrators:(F)
NT AUTHORITY\SYSTEM:(F)
```

Test from WSL2:

```bash
ssh msi hostname
```

For non-admin Windows users, the target file would be:

```text
C:\Users\aaron\.ssh\authorized_keys
```

For this MSI admin setup, use:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

---

# Part 12: Configure mDNS / .local Resolution in WSL2

This fixes errors like:

```text
ssh: Could not resolve hostname orin.local: Name or service not known
```

Inside WSL2:

```bash
sudo apt update
sudo apt install -y avahi-daemon libnss-mdns
sudo systemctl enable --now avahi-daemon
```

Set the `hosts:` line in `/etc/nsswitch.conf`:

```bash
sudo sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
```

Restart services:

```bash
sudo systemctl restart avahi-daemon
sudo systemctl restart systemd-resolved 2>/dev/null || true
```

Validate:

```bash
getent hosts orin.local
getent hosts spark-79b7.local
getent hosts msi.local
```

---

# Part 13: WSL2 SSH Client Config

Inside WSL2, edit:

```bash
nano /home/aaron/.ssh/config
```

Use:

```sshconfig
Host msi
    HostName msi.local
    User aaron
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes

Host orin
    HostName orin.local
    User aaron
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes

Host dgx spark spark-79b7
    HostName spark-79b7.local
    User aaron
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes

Host github.com
    HostName github.com
    User git
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
```

Fix permissions:

```bash
chmod 700 /home/aaron/.ssh
chmod 600 /home/aaron/.ssh/config
chmod 600 /home/aaron/.ssh/id_ed25519
chmod 644 /home/aaron/.ssh/id_ed25519.pub
```

Validate name resolution:

```bash
getent hosts msi.local
getent hosts orin.local
getent hosts spark-79b7.local
```

Validate SSH:

```bash
ssh msi hostname
ssh orin hostname
ssh spark hostname
```

---

# Part 14: DGX SSH Client Config for WSL2

On DGX, edit:

```bash
nano /home/aaron/.ssh/config
```

Add or update:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
```

Fix permissions:

```bash
chmod 700 /home/aaron/.ssh
chmod 600 /home/aaron/.ssh/config
chmod 600 /home/aaron/.ssh/id_ed25519
chmod 644 /home/aaron/.ssh/id_ed25519.pub
```

Test:

```bash
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

---

# Part 15: Orin SSH Client Config for WSL2

On Orin, edit:

```bash
nano /home/aaron/.ssh/config
```

Add or update:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
```

Fix permissions:

```bash
chmod 700 /home/aaron/.ssh
chmod 600 /home/aaron/.ssh/config
chmod 600 /home/aaron/.ssh/id_ed25519
chmod 644 /home/aaron/.ssh/id_ed25519.pub
```

Test:

```bash
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

---

# Part 16: MSI Windows SSH Client Config for WSL2

On MSI Windows PowerShell, edit:

```powershell
notepad C:\Users\aaron\.ssh\config
```

Use:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile C:\Users\aaron\.ssh\id_ed25519
    IdentitiesOnly yes
```

Test from PowerShell:

```powershell
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

Do not rely on `wsl2.local` on MSI Windows unless this works:

```powershell
ping wsl2.local
```

If you want to force Windows name resolution, open Administrator PowerShell:

```powershell
notepad C:\Windows\System32\drivers\etc\hosts
```

Add:

```text
192.168.1.201 wsl2 wsl2.local
```

Then flush DNS:

```powershell
ipconfig /flushdns
```

---

# Part 17: Optional Windows Hosts Entry for WSL2

If Windows cannot resolve `wsl2.local`, use the WSL2 LAN IP in SSH config.

Optional hosts entry on MSI Windows:

```text
192.168.1.201 wsl2 wsl2.local
```

File:

```text
C:\Windows\System32\drivers\etc\hosts
```

Editing requires Administrator privileges.

---

# Part 18: Validation Matrix

> **Automated:** run **WSL2 Verify SSH Topology** (`verify-ssh-topology.yaml`) — it reads all active distros from `WSL2_DISTROS` and tests every bi-directional path, reporting ✅/❌ per path. Manual steps below are for debugging.

## From DGX

```bash
ssh wsl2-dev hostname   # replace 'dev' with your distro name
```

Expected: distro name (e.g. `dev`)

Manual direct test:

```bash
ssh -o BatchMode=yes -p 2222 -i /home/aaron/.ssh/id_ed25519 aaron@<WSL2_HOST> hostname
```

## From Orin

```bash
ssh wsl2-dev hostname
```

Expected: distro name

## From MSI Windows PowerShell

```powershell
ssh wsl2-dev hostname
```

Expected: distro name

## From WSL2

```bash
ssh msi hostname
ssh orin hostname
ssh spark hostname
```

Expected:

```text
MSI Windows hostname
orin
spark-79b7 or DGX hostname
```

## BatchMode Validation

Use this when verifying that passwordless SSH works:

```bash
ssh -o BatchMode=yes wsl2-dev hostname
```

If BatchMode fails, key-based auth is not working and SSH would otherwise have asked for a password.

---

# Part 19: Troubleshooting

## Problem: `ssh wsl2` opens the MSI Windows shell

Cause: client is hitting MSI Windows OpenSSH on port `22`.

Current fix: use the generated alias for the distro:

```bash
ssh wsl2-<name> hostname
```

The `wsl2-<name>` host block is written by **WSL2 Provision** into
`/home/aaron/shared/ssh/config` and starts the distro on demand through Windows
OpenSSH and `wsl.exe`.

Legacy direct-port fallback: WSL2 must use its assigned direct sshd port, and
the client config must include:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
```

On Windows clients, use:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile C:\Users\aaron\.ssh\id_ed25519
    IdentitiesOnly yes
```

---

## Problem: `ssh wsl2-<name>` asks for a password

Cause: the shared SSH store was not mounted before `sshd -i` performed
public-key authentication, or `/home/aaron/shared/ssh/authorized_keys` does not
contain Spark's public key. In current provisioned distros,
`/home/aaron/.ssh/authorized_keys` is a symlink to:

```text
/home/aaron/shared/ssh/authorized_keys
```

Current fix: rerun **Setup Shared SSH Store** if the shared store is broken,
then rerun **WSL2 Provision** for the affected distro. Do not replace the
symlink with a local per-distro `authorized_keys` file.

Legacy direct-port fallback: from the Linux client, run:

```bash
ssh-copy-id -p 2222 -i /home/aaron/.ssh/id_ed25519.pub aaron@192.168.1.201
```

Then test:

```bash
ssh -o BatchMode=yes -p 2222 -i /home/aaron/.ssh/id_ed25519 aaron@192.168.1.201 hostname
```

Expected:

```text
wsl2
```

Fix legacy WSL2 permissions if needed:

```bash
chmod 700 /home/aaron/.ssh
chmod 600 /home/aaron/.ssh/authorized_keys
chown -R aaron:aaron /home/aaron/.ssh
sudo systemctl restart ssh
```

---

## Problem: `ssh: Could not resolve hostname orin.local`

Cause: WSL2 lacks mDNS support.

Fix inside WSL2:

```bash
sudo apt update
sudo apt install -y avahi-daemon libnss-mdns
sudo systemctl enable --now avahi-daemon
sudo sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
sudo systemctl restart avahi-daemon
sudo systemctl restart systemd-resolved 2>/dev/null || true
```

Validate:

```bash
getent hosts orin.local
getent hosts spark-79b7.local
getent hosts msi.local
```

---

## Problem: Windows cannot resolve `wsl2.local`

Use the WSL2 IP in `C:\Users\aaron\.ssh\config`:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile C:\Users\aaron\.ssh\id_ed25519
    IdentitiesOnly yes
```

Optional Administrator PowerShell fix:

```powershell
notepad C:\Windows\System32\drivers\etc\hosts
```

Add:

```text
192.168.1.201 wsl2 wsl2.local
```

Then:

```powershell
ipconfig /flushdns
```

---

## Problem: Windows firewall command fails

Cause: not running as Administrator.

Fix: open Administrator PowerShell and rerun:

```powershell
New-NetFirewallRule `
  -DisplayName "WSL2 SSH 2222 Inbound" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 2222 `
  -Action Allow
```

---

## Problem: WSL2 hostname did not change

Check:

```bash
cat /etc/wsl.conf
```

Expected:

```ini
[network]
hostname=wsl2
generateHosts=true
generateResolvConf=true
```

Then from Windows PowerShell:

```powershell
wsl --shutdown
wsl
```

Verify in WSL2:

```bash
hostname
```

Expected:

```text
wsl2
```

---

# Part 20: Final Known-Good Commands

Replace `<name>` with the WSL2 distro name (e.g. `dev`).

## From DGX to WSL2

```bash
ssh wsl2-<name> hostname
```

## From Orin to WSL2

```bash
ssh wsl2-<name> hostname
```

## From MSI Windows to WSL2

```powershell
ssh wsl2-<name> hostname
```

## From WSL2 to MSI

```bash
ssh msi hostname
```

## From WSL2 to Orin

```bash
ssh orin hostname
```

## From WSL2 to DGX

```bash
ssh spark hostname
```

---

# End State

After this runbook is complete:

```text
DGX  -> ssh wsl2-<name> -> WSL2 distro Linux shell through on-demand wsl.exe
Orin -> ssh wsl2-<name> -> WSL2 distro Linux shell through on-demand wsl.exe
MSI  -> direct Windows wsl.exe or direct sshd port for manual diagnostics
WSL2 -> ssh msi         -> MSI Windows shell on port 22
WSL2 -> ssh orin        -> Jetson Orin
WSL2 -> ssh spark       -> DGX / Spark
```

All SSH paths use `id_ed25519` keys. SSH config, `known_hosts`, and `authorized_keys` are
managed centrally in `/home/aaron/shared/ssh/` on DGX. DGX symlinks
`/home/aaron/.ssh/` to the shared store. Orin and each WSL2 distro CIFS-mount
Spark's `/home/aaron/shared/` and symlink `/home/aaron/.ssh/` to
`/home/aaron/shared/ssh/`, sharing Spark's SSH identity.
