# WSL2 Post-Bootstrap: SSH Mesh Setup

> **These steps are automated.** After running **WSL2 Provision**, run
> **WSL2 Post-Provision** (`.github/workflows/post-provision-wsl2.yaml`), then
> **WSL2 Verify SSH Topology** (`.github/workflows/verify-ssh-topology.yaml`) to
> confirm everything works.
>
> The manual steps below are kept as a reference and fallback only.

---

## One-time template steps (run once after bootstrap.sh, before provisioning distros)

`bootstrap.sh` bakes the Samba credentials and a template SMB keypair into the distro
before it is exported. These steps wire the template key into the shared SSH store so
new distros can authenticate without any secret delivery at provision time.

1. **Run `bootstrap.sh`** inside the distro with `DGX_SMB_PASSWORD` set (or enter it
   when prompted). It generates `~/.ssh/id_ed25519_smb` and `~/.smbcredentials`.

2. **Commit the template public key** to the repo:
   ```bash
   # Inside the WSL2 distro after bootstrap.sh:
   cat ~/.ssh/id_ed25519_smb.pub
   # Copy the output, then on the host:
   # git checkout -b feat/new-template
   # echo '<paste>' > wsl2/id_ed25519_smb.pub
   # git add wsl2/id_ed25519_smb.pub && git commit -m "feat: update template SMB key"
   # git push
   ```

3. **Export the distro** from PowerShell:
   ```powershell
   wsl --export <name> C:\wsl-templates\ubuntu-22.04-configured-template.tar
   ```

4. **Run Setup Shared SSH Store** workflow — pre-authorizes the template key on DGX
   and wires Orin via `orin-ssh-setup.service`.

After these four steps, `DGX_SMB_PASSWORD` is no longer needed at provision time.

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
> **No `DGX_SMB_PASSWORD` is required at provision time** — the Samba credentials are
> baked into the template by `bootstrap.sh`.

The workflow handles:
- **Step 4** (WSL2 pubkey → DGX + Orin): `wsl2-ssh-setup.service` (pre-installed by
  `bootstrap.sh`) runs `setup-shared-ssh.sh` via smbclient. It downloads SSH files from
  DGX, appends the distro's pubkey to `authorized_keys`, and uploads it back.
- **Step 5** (DGX + Orin pubkeys → WSL2): The shared `authorized_keys` downloaded in
  step 4 already contains all machine pubkeys (seeded when Setup Shared SSH Store ran).
- **Step 6** (SSH client config on DGX + Orin): The `wsl2-<name>` host block is written
  to the shared `~/shared/ssh/config`, which all machines pick up automatically via their
  smbclient sync on next start.
- **Step 7** (SSH client config on Windows): `%USERPROFILE%\.ssh\config` is hardlinked
  to `C:\Users\aaron\shared\ssh\config` by `post-provision.ps1`.

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
