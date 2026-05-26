# WSL2 Post-Bootstrap: SSH Mesh Setup

> **These steps are automated.** After running **WSL2 Provision**
> (`.github/workflows/provision-wsl2.yaml`), run
> **WSL2 Verify SSH Topology** (`.github/workflows/verify-ssh-topology.yaml`) to
> confirm everything works.
>
> The manual steps below are kept as a reference and fallback only.

---

## One-time template steps (run once after bootstrap.sh, before provisioning distros)

`bootstrap.sh` bakes Samba credentials and Spark's pubkey into the distro before it is
exported. These steps wire the template key into the shared SSH store so new distros can
authenticate without any secret delivery at provision time.

1. **Run `bootstrap.sh`** inside the distro with env vars set:
   ```bash
   DGX_SMB_PASSWORD=<samba-password> \
   DGX_PUBKEY="$(ssh spark cat ~/.ssh/id_ed25519.pub)" \
   ./bootstrap.sh
   ```
   This bakes `.smbcredentials` (so no runtime password delivery) and seeds Spark's pubkey
   into `authorized_keys` (so `DGX_HOST_SSH_KEY` can SSH into fresh distros).

2. **Commit the template public key** to the repo:
   ```bash
   # bootstrap.sh prints id_ed25519_smb.pub at the end. Copy it, then:
   echo '<paste>' > wsl2/id_ed25519_smb.pub
   git add wsl2/id_ed25519_smb.pub && git commit -m "feat: update template SMB key"
   git push
   ```

3. **Export the distro** from PowerShell:
   ```powershell
   wsl --export <name> C:\wsl-templates\ubuntu-22.04-configured-template.tar
   ```

4. **Run Setup Shared SSH Store** workflow — initialises `~/shared/ssh/` on DGX, creates
   `~/.ssh` symlinks on DGX, pre-authorizes the template SMB key on DGX, and wires Orin
   (CIFS mount of `//DGX/shared` + symlinks `~/.ssh/ → ~/shared/ssh/`).

After these four steps, all subsequent provisioning is handled by the **WSL2 Provision**
workflow — no manual secret delivery required.

---

These steps cannot be scripted inside `bootstrap.sh` — they require either Windows
Administrator access, a `wsl --shutdown` cycle that ends the session, or being on a
different machine to push keys.

### Multi-instance note

Each WSL2 distro gets its own **named SSH alias** (`wsl2-<distro_name>`, e.g.
`wsl2-dev`, `wsl2-ml`) and its own **sshd port** (2222 for the first instance;
increment by 1 for each additional). Pass `ssh_port` when running
**WSL2 Provision** and **WSL2 Verify SSH Topology**.

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

Since all distros share Spark's SSH identity, the key that needs to be added to Windows
is `id_ed25519.pub` from the shared store (`~/shared/ssh/id_ed25519.pub`).

On **MSI Windows** open **Administrator PowerShell** and edit:

```powershell
notepad C:\ProgramData\ssh\administrators_authorized_keys
```

Paste Spark's public key as one complete line, save.

Fix permissions (required by Windows OpenSSH):

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "Administrators:F"
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "SYSTEM:F"
Restart-Service sshd
```

---

## Steps 4–5 — Automated by WSL2 Provision

> **These steps are fully automated by the WSL2 Provision workflow.**
> **Secrets needed:** `WSL2_HOST`, `DGX_HOST_SSH_KEY`, `DGX_SMB_PASSWORD`
> **Vars needed:** `DGX_HOST`, `DGX_HOST_USER`

The workflow:
- **Step 4** (write `.smbcredentials`): SSHes into the distro using `DGX_HOST_SSH_KEY`
  and writes `.smbcredentials` via stdin (password never in args).
- **Step 5** (CIFS mount + SSH symlinks): calls `setup-shared-ssh.sh` as root inside the
  distro. The script mounts `//DGX/shared` at `~/shared/` via CIFS, then symlinks all
  `~/.ssh/` files (`config`, `known_hosts`, `authorized_keys`, `id_ed25519`,
  `id_ed25519.pub`) to `~/shared/ssh/`. Also writes the `wsl2-<name>` host block directly
  to the shared `config` (write goes straight to DGX via CIFS).

All distros share Spark's SSH identity — there is no per-distro keypair.

**Manual fallback** (if the workflow fails):

```bash
# On the distro (as root):
/usr/local/bin/setup-shared-ssh.sh spark-79b7.local <user> <distro_name> <port>
```

---

## Validation matrix

| From | Command | Expected |
|------|---------|----------|
| WSL2 | `ssh orin hostname` | `orin` |
| WSL2 | `ssh spark hostname` | `spark-79b7` (or DGX hostname) |
| DGX | `ssh wsl2-dev hostname` | `dev` |
| Orin | `ssh wsl2-dev hostname` | `dev` |

BatchMode test (confirms no password fallback):

```bash
ssh -o BatchMode=yes wsl2-dev hostname
```

---

## Reference

Full details and troubleshooting: [docs/ssh-runbook.md](../docs/ssh-runbook.md)
