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

### Multi-instance note

Each WSL2 distro gets its own **named SSH alias** (`wsl2-<distro_name>`, e.g.
`wsl2-dev`, `wsl2-ml`) and its own **sshd port** (2222 for the first instance;
increment by 1 for each additional). Pass `ssh_port` when running
**WSL2 Post-Provision** and **WSL2 Verify SSH Topology**.

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

## Step 2 — Windows Firewall: allow distro's sshd port inbound

WSL2 sshd listens on the port chosen at provision time (default 2222). Open an
**Administrator PowerShell** and run (replace `2222` with your distro's port):

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

From **DGX**, push its key to WSL2 (using the Windows host's IP and the distro's port):

```bash
ssh-copy-id -p 2222 -i ~/.ssh/id_ed25519.pub aaron@<WSL2_HOST>
```

From **Orin**:

```bash
ssh-copy-id -p 2222 -i ~/.ssh/id_ed25519.pub aaron@<WSL2_HOST>
```

Test from DGX:

```bash
ssh -o BatchMode=yes wsl2-dev hostname   # expected: dev
```

Test from Orin:

```bash
ssh -o BatchMode=yes wsl2-dev hostname   # expected: dev
```

---

## Step 6 — SSH client configs on DGX and Orin

Both machines need `~/.ssh/config` to reach WSL2 by the per-distro alias. The
alias is `wsl2-<distro_name>` and `HostName` is the Windows host (not a WSL2 IP —
mirrored networking means WSL2 sshd is reachable via the Windows host address).

**On DGX** (`ssh spark`):

```bash
cat >> ~/.ssh/config << 'EOF'

Host wsl2-dev
    HostName <WSL2_HOST>
    User aaron
    Port 2222
    IdentityFile /home/aaron/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

**On Orin** (`ssh orin`): same block.

---

## Step 7 — SSH client config on MSI Windows (for `ssh wsl2-<distro>`)

On **MSI Windows** PowerShell, add a block to `%USERPROFILE%\.ssh\config`:

```sshconfig
Host wsl2-dev
    HostName localhost
    User aaron
    Port 2222
    IdentityFile C:\Users\aaron\.ssh\id_ed25519
    IdentitiesOnly yes
```

> Windows SSH config uses `HostName localhost` because the distro sshd runs on
> the same machine. DGX and Orin use the Windows host's network name/IP.

Test:

```powershell
ssh wsl2-dev hostname   # expected: dev
```

---

## Validation matrix

| From | Command | Expected |
|------|---------|----------|
| WSL2 | `ssh msi hostname` | MSI Windows hostname |
| WSL2 | `ssh orin hostname` | `orin` |
| WSL2 | `ssh spark hostname` | `spark-79b7` (or DGX hostname) |
| DGX | `ssh wsl2-dev hostname` | `dev` |
| Orin | `ssh wsl2-dev hostname` | `dev` |
| MSI Windows | `ssh wsl2-dev hostname` | `dev` |

BatchMode test (confirms no password fallback):

```bash
ssh -o BatchMode=yes wsl2-dev hostname
```

---

## Reference

Full details and troubleshooting: [docs/ssh-runbook.md](../docs/ssh-runbook.md)
