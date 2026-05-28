# WSL2 Dev Environments

[Windows Subsystem for Linux 2](https://github.com/microsoft/WSL) ([docs](https://learn.microsoft.com/en-us/windows/wsl/)) — provision and remove Windows-hosted WSL2 distros from [GitHub Actions](https://github.com/features/actions). Each
distro is imported from a configured template tarball on the Windows host, wired
into the shared lab SSH store, and reached through the `wsl2-<name>` SSH alias.

For the architecture, lifecycle model, troubleshooting, and manual procedures,
see [TECHNICAL.md](TECHNICAL.md).

## Quick Start

Provision the first distro:

```text
Actions -> WSL2 Provision -> distro_name: dev  ssh_port: 2222
Actions -> WSL2 Verify SSH Topology
```

Provision an additional distro with a unique direct sshd port:

```text
Actions -> WSL2 Provision -> distro_name: test  ssh_port: 2223
Actions -> WSL2 Verify SSH Topology
```

Unprovision a distro:

```text
Actions -> WSL2 Unprovision -> distro_name: dev  delete_files: false
```

Normal SSH uses the shared alias:

```bash
ssh wsl2-dev hostname
```

## Workflows

| Workflow | Purpose |
| --- | --- |
| **WSL2 Provision** (`provision-wsl2.yaml`) | Imports a distro from the configured template, runs `firstboot.sh`, writes the shared SSH alias, and registers the distro in `WSL2_DISTROS`. |
| **WSL2 Verify SSH Topology** (`verify-ssh-topology.yaml`) | Tests supported Spark, Orin, and active WSL2 SSH paths. |
| **WSL2 Unprovision** (`unprovision-wsl2.yaml`) | Unregisters a distro and optionally deletes `C:\wsl\<name>`. |

WSL2-to-WSL2 peer paths are intentionally not part of CI. Spark and Orin are the
durable SSH control plane; WSL2 distros are on-demand endpoints.

## Prerequisites

On the Windows host:

1. Enable OpenSSH Server.
2. Set PowerShell as the default OpenSSH shell.
3. Authorize Spark's public key for the Windows user.
4. Enable WSL mirrored networking in `$env:USERPROFILE\.wslconfig`.
5. Build or rebuild the configured template tarball.

OpenSSH setup details are in [ssh-win.md](ssh-win.md). The WSL lifecycle and
networking rationale are in [TECHNICAL.md](TECHNICAL.md).

Minimal mirrored networking config:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
firewall=true
```

Then restart WSL:

```powershell
wsl --shutdown
wsl
```

## Secrets and Vars

| Secret / Var | Value | Used by |
| --- | --- | --- |
| `WSL2_HOST` (secret) | Windows hostname or IP, for example `msi.local` | provision, verify, unprovision |
| `WSL2_HOST_USER` (secret) | Windows SSH username | provision, verify, unprovision |
| `WSL2_HOST_SSH_KEY` (secret) | Private key authorized on Windows | provision, verify, unprovision |
| `DGX_HOST_SSH_KEY` (secret) | Spark private key used for distro auth and verification | provision, verify |
| `DGX_HOST_IP` (var) | DGX static IP for SSH and CIFS | provision, setup, deploy workflows |
| `DGX_HOST_USER` (var) | DGX / Samba username | provision |
| `WSL2_DISTROS` (repo var) | `NONE` initially | Tracks active distro names |

`DGX_SMB_PASSWORD` is not required by `WSL2 Provision`; Samba credentials are
baked into the template by `rebuild-template.ps1`.

## Template

The provision workflow imports from this Windows-local tarball:

```text
C:\wsl-templates\ubuntu-22.04-configured-template.tar
```

Rebuild it after `bootstrap.sh` changes or when rotating the Samba password:

```powershell
cd path\to\miramar-platform-gcp\wsl2
.\rebuild-template.ps1 -SmbPassword <samba-password>
```

After rebuilding, run:

```text
Actions -> Setup Shared SSH Store
Actions -> WSL2 Provision -> distro_name: test  ssh_port: 2223
Actions -> WSL2 Verify SSH Topology
```

Do not commit the tarball or upload it as a GitHub artifact. It is large,
machine-local, and contains baked-in local configuration.

## Ports

Each active distro needs a unique direct sshd port for provisioning checks and
manual diagnostics. Normal SSH still uses the `wsl2-<name>` alias through
Windows OpenSSH.

Common assignments:

```text
dev  -> 2222
test -> 2223
```

Probe a candidate range before adding more distros:

```powershell
cd path\to\miramar-platform-gcp\wsl2
.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299
```

## Validation

After provisioning, run **WSL2 Verify SSH Topology**. For a quick manual check:

```bash
ssh -o BatchMode=yes wsl2-dev hostname
```

Expected basic paths:

| From | Command | Expected |
| --- | --- | --- |
| WSL2 | `ssh orin hostname` | `orin` |
| WSL2 | `ssh spark hostname` | DGX hostname |
| DGX | `ssh wsl2-dev hostname` | `dev` |
| Orin | `ssh wsl2-dev hostname` | `dev` |

## References

| Technology | GitHub | Docs |
|---|---|---|
| [WSL2](https://learn.microsoft.com/en-us/windows/wsl/) | [microsoft/WSL](https://github.com/microsoft/WSL) | [install guide](https://learn.microsoft.com/en-us/windows/wsl/install) |
| [GitHub Actions](https://github.com/features/actions) | — | [docs](https://docs.github.com/en/actions) |

- [TECHNICAL.md](TECHNICAL.md): architecture, lifecycle model, template rules,
  troubleshooting, and manual setup
- [ssh-win.md](ssh-win.md): Windows OpenSSH setup
- [docs/ssh-runbook.md](../docs/ssh-runbook.md): broader lab SSH runbook
