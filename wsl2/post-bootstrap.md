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

## Steps 4–7 — Automated by WSL2 Post-Provision

> **These steps are fully automated by the WSL2 Post-Provision workflow.** Run it instead.

The workflow handles:
- **Step 4** (WSL2 pubkey → DGX + Orin): WSL2 pubkey is written to the shared `authorized_keys` via `~/shared/ssh/authorized_keys` (accessible to all machines via the CIFS mount).
- **Step 5** (DGX + Orin pubkeys → WSL2): DGX and Orin runner pubkeys are injected into WSL2 `authorized_keys` directly.
- **Step 6** (SSH client config on DGX + Orin): The `wsl2-<name>` host block is written to the shared `~/shared/ssh/config`, which all machines pick up automatically via their `~/.ssh/config` symlink.
- **Step 7** (SSH client config on Windows): `%USERPROFILE%\.ssh\config` is hardlinked to `C:\Users\aaron\shared\ssh\config` by `post-provision.ps1`.

**Manual fallback** (if the workflow fails and you need to wire a machine by hand):

```bash
# From the machine that needs access to WSL2, add its pubkey to shared authorized_keys:
cat ~/.ssh/id_ed25519.pub >> ~/shared/ssh/authorized_keys

# Add wsl2-<name> host block to shared config:
cat >> ~/shared/ssh/config << 'EOF'

Host wsl2-<name>
    HostName <WSL2_HOST>
    User aaron
    Port <PORT>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
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
