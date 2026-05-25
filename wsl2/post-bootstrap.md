# WSL2 Post-Bootstrap: SSH Mesh Setup

> **These steps are automated.** After running **WSL2 Provision**, run
> **WSL2 Post-Provision** (`.github/workflows/post-provision-wsl2.yaml`), then
> **WSL2 Verify SSH Topology** (`.github/workflows/verify-ssh-topology.yaml`) to
> confirm everything works.
>
> The manual steps below are kept as a reference and fallback only.

---

These steps cannot be scripted inside `bootstrap.sh` — they require either Windows
Administrator access, a `wsl --shutdown` cycle that ends the session, or being on a
different machine to push keys.

---

## Step 1 — Windows `.wslconfig` (mirrored networking)

On **MSI Windows**, open PowerShell (no elevation needed) and edit:

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

> Do **not** include `localhostForwarding=true` — it has no effect in mirrored mode
> and causes a warning.

Then restart WSL:

```powershell
wsl --shutdown
wsl
```

---

## Step 2 — Windows Firewall: allow port 2222 inbound

WSL2 sshd listens on port 2222. Open an **Administrator PowerShell** and run:

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

## Step 3 — Add WSL2 public key to MSI Windows (admin authorized keys)

`bootstrap.sh` prints the WSL2 public key at the end. Copy it, then on **MSI Windows**
open **Administrator PowerShell** and edit:

```powershell
notepad C:\ProgramData\ssh\administrators_authorized_keys
```

Paste the WSL2 public key as one complete line, save.

Fix permissions (required by Windows OpenSSH):

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "Administrators:F"
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "SYSTEM:F"
Restart-Service sshd
```

Test from WSL2:

```bash
ssh msi hostname
```

> **Non-admin Windows users** use `C:\Users\aaron\.ssh\authorized_keys` instead.

---

## Step 4 — Distribute WSL2 public key to DGX and Orin

From **WSL2**, push the key to each machine:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub aaron@spark-79b7.local
ssh-copy-id -i ~/.ssh/id_ed25519.pub aaron@orin.local
```

Test:

```bash
ssh spark hostname
ssh orin hostname
```

---

## Step 5 — Add DGX and Orin public keys to WSL2

From **DGX**, push its key to WSL2 (using its LAN IP and port 2222):

```bash
ssh-copy-id -p 2222 -i ~/.ssh/id_ed25519.pub aaron@192.168.1.201
```

From **Orin**:

```bash
ssh-copy-id -p 2222 -i ~/.ssh/id_ed25519.pub aaron@192.168.1.201
```

Test from DGX:

```bash
ssh -o BatchMode=yes wsl2 hostname   # expected: wsl2
```

Test from Orin:

```bash
ssh -o BatchMode=yes wsl2 hostname   # expected: wsl2
```

---

## Step 6 — SSH client configs on DGX and Orin

Both machines need `~/.ssh/config` to reach WSL2 by name. Run on each.

**On DGX** (`ssh spark`):

```bash
cat >> ~/.ssh/config <<'EOF'

Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

**On Orin** (`ssh orin`):

```bash
cat >> ~/.ssh/config <<'EOF'

Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

---

## Step 7 — SSH client config on MSI Windows (for `ssh wsl2`)

On **MSI Windows** PowerShell:

```powershell
notepad C:\Users\aaron\.ssh\config
```

Add:

```sshconfig
Host wsl2
    HostName 192.168.1.201
    User aaron
    Port 2222
    IdentityFile C:\Users\aaron\.ssh\id_ed25519
    IdentitiesOnly yes
```

Test:

```powershell
ssh wsl2 hostname   # expected: wsl2
```

> If `wsl2.local` does not resolve on Windows, add a static hosts entry:
> `192.168.1.201 wsl2 wsl2.local` in
> `C:\Windows\System32\drivers\etc\hosts` (requires Administrator), then
> `ipconfig /flushdns`.

---

## Validation matrix

| From | Command | Expected |
|------|---------|----------|
| WSL2 | `ssh msi hostname` | MSI Windows hostname |
| WSL2 | `ssh orin hostname` | `orin` |
| WSL2 | `ssh spark hostname` | `spark-79b7` (or DGX hostname) |
| DGX | `ssh wsl2 hostname` | `wsl2` |
| Orin | `ssh wsl2 hostname` | `wsl2` |
| MSI Windows | `ssh wsl2 hostname` | `wsl2` |

BatchMode test (confirms no password fallback):

```bash
ssh -o BatchMode=yes wsl2 hostname
```

---

## Reference

Full details and troubleshooting: [docs/ssh-runbook.md](../docs/ssh-runbook.md)
