# WSL2 Dev Environments

## GHA Workflows

Provision and unprovision WSL2 distros from the configured template tarball via GitHub Actions.

| Workflow | Purpose |
|---|---|
| **WSL2 Provision** (`provision-wsl2.yaml`) | Import a new distro from `C:\wsl-templates\ubuntu-22.04-configured-template.tar` |
| **WSL2 Post-Provision** (`post-provision-wsl2.yaml`) | Wire up the SSH mesh: `.wslconfig`, firewall, sshd port, write distro name, start `wsl2-ssh-setup.service` (smbclient syncs SSH files — no `DGX_SMB_PASSWORD` needed; creds baked in template) |
| **WSL2 Verify SSH Topology** (`verify-ssh-topology.yaml`) | Validate every SSH path in the mesh (DGX↔WSL2, Orin↔WSL2, Windows↔WSL2, WSL2→all) |
| **WSL2 Unprovision** (`unprovision-wsl2.yaml`) | Unregister a distro; optionally delete the folder at `C:\wsl\<name>` |

Normal provisioning sequence:

```
Actions → WSL2 Provision          → distro_name: dev
Actions → WSL2 Post-Provision     → distro_name: dev
Actions → WSL2 Verify SSH Topology → distro_name: dev
```

Teardown:

```
Actions → WSL2 Unprovision → distro_name: dev  delete_files: false
```

Both workflows SSH into the Windows laptop from a self-hosted runner (`dgx`, `agx`, or `wsl2`).

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

**3. Authorize the SSH key**

Add the public key to `C:\Users\<user>\.ssh\authorized_keys`.

**4. Create the template tarball** (one-time, see [Build a configured template](#build-a-configured-template) below).

**5. Set GitHub secrets** (repo or org level):

| Secret | Value |
|---|---|
| `WSL2_HOST` | Windows hostname or IP (e.g. `msi-laptop.local`) |
| `WSL2_HOST_USER` | Windows username |
| `WSL2_HOST_SSH_KEY` | Private SSH key (PEM format) |

---

# Manual Setup

## Rebuild the configured template

Use this when `bootstrap.sh` has changed and you need to bake the updates
(e.g. new SMB keypair, new tools) into the tarball. Starts from the existing
`ubuntu-22.04-configured-template.tar` — no fresh install needed.

### Step 1 — Import existing tarball as a working distro (PowerShell)

```powershell
mkdir C:\wsl\Ubuntu-Rebuild -Force
wsl --import Ubuntu-Rebuild C:\wsl\Ubuntu-Rebuild C:\wsl-templates\ubuntu-22.04-configured-template.tar --version 2
wsl -d Ubuntu-Rebuild --cd ~
```

### Step 2 — Pull latest bootstrap.sh and run it (inside the distro)

```bash
curl -fsSL https://raw.githubusercontent.com/miramar-labs-org/miramar-platform-gcp/main/wsl2/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
DGX_SMB_PASSWORD=<samba-password> ./bootstrap.sh
```

bootstrap.sh is idempotent — it skips anything already installed and adds what’s missing.
At the end it prints two public keys. Copy the **SMB bootstrap key** (`id_ed25519_smb.pub`).

### Step 3 — Export, overwriting the existing tarball (PowerShell)

```powershell
wsl --shutdown
wsl --export Ubuntu-Rebuild C:\wsl-templates\ubuntu-22.04-configured-template.tar
wsl --unregister Ubuntu-Rebuild
rmdir C:\wsl\Ubuntu-Rebuild
```

### Step 4 — Commit the SMB public key to the repo (DGX or any dev machine)

```bash
echo ‘<paste id_ed25519_smb.pub here>’ > wsl2/id_ed25519_smb.pub
git add wsl2/id_ed25519_smb.pub
git commit -m "feat: update template SMB bootstrap public key"
git push
```

### Step 5 — Run Setup Shared SSH Store workflow

Pre-authorizes the template SMB key on DGX and wires Orin via `orin-ssh-setup.service`.
Requires `DGX_SMB_PASSWORD` secret. This is the **last time** that secret is needed — all
subsequent per-distro provisioning is secret-free.

### Step 6 — Provision a distro to verify

```
Actions → WSL2 Provision          → distro_name: test
Actions → WSL2 Post-Provision     → distro_name: test
Actions → WSL2 Verify SSH Topology → distro_name: test
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

Install the latest NVIDIA Windows driver that supports WSL2 CUDA. NVIDIA’s WSL guide emphasizes: install the Windows driver only (don’t install a Linux display driver inside WSL).
[NVIDIA Docs](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)

[v591.44](https://www.nvidia.com/en-us/drivers/details/258748/)

After driver install, inside WSL you should eventually be able to run:

    nvidia-smi

### Enable passwordless sudo in distro

    sudo visudo -f /etc/sudoers.d/aaron

add:

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

Inside the distro:

    DGX_SMB_PASSWORD=<samba-password> ./bootstrap.sh

Configure p10k, then:

    wsl --shutdown

### Export the configured template (PowerShell)

    wsl --export Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-configured-template.tar

### Cleanup (PowerShell)

    wsl --unregister Ubuntu-22.04
    wsl --unregister Ubuntu2204-Base

Then follow Steps 4–6 from [Rebuild](#rebuild-the-configured-template) above (commit SMB key, run Setup Shared SSH Store, provision a test distro).

---

### Bring up a distro manually (without GHA)

    wsl --import Ubuntu2204-Dev1 C:\wsl\Ubuntu2204-Dev1 C:\wsl-templates\ubuntu-22.04-configured-template.tar --version 2
    wsl -d Ubuntu2204-Dev1 --cd ~
    