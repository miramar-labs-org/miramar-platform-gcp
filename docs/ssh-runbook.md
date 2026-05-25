# SSH Runbook: DGX, Orin, MSI, and WSL2

This runbook documents the SSH and DNS setup for a local lab consisting of:

| Machine | Hostname | DNS |
|---|---|---|
| DGX / Spark | `spark-79b7` | `spark-79b7.local` |
| Jetson Orin | `orin` | `orin.local` |
| MSI Windows laptop | `msi` | `msi.local` |
| WSL2 on MSI | `wsl2` | `wsl2.local` *(unreliable on Windows — use IP `192.168.1.201` in SSH configs)* |

The goal is seamless SSH between all machines using `id_ed25519` keys.

---

## Final Topology

```text
ssh msi   -> MSI Windows OpenSSH shell on port 22
ssh wsl2  -> WSL2 Linux shell on port 2222
ssh orin  -> Jetson Orin
ssh spark -> DGX / Spark
```

Important distinction:

```text
MSI Windows OpenSSH uses port 22.
WSL2 sshd uses port 2222.
```

This avoids the problem where `ssh wsl2` accidentally lands in the MSI Windows shell.

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
6. `wsl2` means WSL2 Linux sshd on port `2222`.
7. Prefer the WSL2 LAN IP for `wsl2` SSH configs unless `wsl2.local` is proven to resolve.
8. The DGX host is `spark-79b7.local`; do not mistype it as `spar-79b7.local`.
9. Windows firewall changes require Administrator PowerShell.
10. If `ssh wsl2` opens the MSI Windows shell, the SSH client is hitting port `22` instead of WSL2 port `2222`.

---

## Assumptions

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

## From DGX

```bash
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

Manual direct test:

```bash
ssh -o BatchMode=yes -p 2222 -i /home/aaron/.ssh/id_ed25519 aaron@192.168.1.201 hostname
```

Expected:

```text
wsl2
```

## From Orin

```bash
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

## From MSI Windows PowerShell

```powershell
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

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
ssh -o BatchMode=yes wsl2 hostname
```

Expected:

```text
wsl2
```

If BatchMode fails, key-based auth is not working and SSH would otherwise have asked for a password.

---

# Part 19: Troubleshooting

## Problem: `ssh wsl2` opens the MSI Windows shell

Cause: client is hitting MSI Windows OpenSSH on port `22`.

Fix: WSL2 must use port `2222`, and the client config must include:

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

## Problem: `ssh wsl2` asks for a password

Cause: WSL2 does not have the client machine's public key in:

```text
/home/aaron/.ssh/authorized_keys
```

From the Linux client, run:

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

Fix WSL2 permissions if needed:

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

## From DGX to WSL2

```bash
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

## From Orin to WSL2

```bash
ssh wsl2 hostname
```

Expected:

```text
wsl2
```

## From MSI Windows to WSL2

```powershell
ssh wsl2 hostname
```

Expected:

```text
wsl2
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
DGX  -> ssh wsl2 -> WSL2 Linux shell on port 2222
Orin -> ssh wsl2 -> WSL2 Linux shell on port 2222
MSI  -> ssh wsl2 -> WSL2 Linux shell on port 2222
WSL2 -> ssh msi  -> MSI Windows shell on port 22
WSL2 -> ssh orin -> Jetson Orin
WSL2 -> ssh spark -> DGX / Spark
```

All SSH paths use `id_ed25519` keys and absolute paths in SSH config files.
