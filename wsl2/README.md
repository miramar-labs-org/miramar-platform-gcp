# WSL2 Dev Environments

## GHA Workflows

Provision and unprovision WSL2 distros from the configured template tarball via GitHub Actions.

| Workflow | Purpose |
|---|---|
| **WSL2 Provision** (`provision-wsl2.yaml`) | Import a new distro from `C:\wsl-templates\ubuntu-22.04-configured-template.tar` |
| **WSL2 Post-Provision** (`post-provision-wsl2.yaml`) | Wire up the full SSH mesh: `.wslconfig`, firewall, key distribution, SSH configs on all machines |
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

## Build a configured template

        wsl --update

        wsl --install -d Ubuntu-22.04

## GPU (only if you want NVIDIA containers)

Install the latest NVIDIA Windows driver that supports WSL2 CUDA. NVIDIA’s WSL guide emphasizes: install the Windows driver only (don’t install a Linux display driver inside WSL).
[NVIDIA Docs](https://docs.nvidia.com/cuda/wsl-user-guide/index.html)

[v591.44](https://www.nvidia.com/en-us/drivers/details/258748/)

After driver install, inside WSL you should eventually be able to run:

    nvidia-smi

## Enable passwordless sudo in distro

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


Copy `bootstrap.sh` into distro $HOME, then:

    chmod +x bootstrap.sh


## Back in PowerShell:

    wsl --shutdown

## Export 'golden image':

    wsl --shutdown
    wsl --list --verbose
    mkdir C:\wsl-templates -Force
    
    wsl --export Ubuntu-22.04 C:\wsl-templates\ubuntu-22.04-base-template.tar

## Import fresh copy from snapshot:

    mkdir C:\wsl\Ubuntu2204-Base -Force
    wsl --import Ubuntu2204-Base C:\wsl\Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-base-template.tar --version 2
    wsl -d Ubuntu2204-Base --cd ~

Run bootsrtap.sh:

    bootstrap.sh

Restart Ubuntu2024-Base to manually configure p10k:

    wsl --shutdown
    wsl -d Ubuntu2204-Base --cd ~

Distro is now configured. We now snapshot this 'configured' instance too:

    wsl --shutdown
    wsl --export Ubuntu2204-Base C:\wsl-templates\ubuntu-22.04-configured-template.tar

Cleanup:

    wsl --unregister Ubuntu-22.04
    wsl --unregister Ubuntu2204-Base

Finally, bring up a fresh configured instance :

    wsl --import Ubuntu2204-Dev1 C:\wsl\Ubuntu2204-Dev1 C:\wsl-templates\ubuntu-22.04-configured-template.tar --version 2
    wsl -d Ubuntu2204-Dev1 --cd ~
    