# SSH Runbook: DGX, Orin, MSI, and WSL2

This runbook documents the current SSH topology for the lab. The normal path is
automated by GitHub Actions workflows and uses Spark's shared SSH store.

For WSL2 lifecycle details, read [../wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md).
For WSL2 operator commands, read [../wsl2/README.md](../wsl2/README.md).

## Current Model

Spark owns the canonical SSH store:

```text
/home/aaron/shared/ssh
```

Important files:

```text
/home/aaron/shared/ssh/config
/home/aaron/shared/ssh/known_hosts
/home/aaron/shared/ssh/authorized_keys
/home/aaron/shared/ssh/id_ed25519
/home/aaron/shared/ssh/id_ed25519.pub
```

DGX, Orin, and WSL2 distros symlink `/home/aaron/.ssh/*` into that shared store.
All machines use Spark's `id_ed25519` identity. Do not create per-machine or
per-distro SSH identities for the normal lab topology.

## Machines

| Machine | Hostname | DNS | SSH alias |
| --- | --- | --- | --- |
| DGX / Spark | `spark-79b7` | `spark-79b7.local` | `spark`, `dgx` |
| Jetson Orin | `orin` | `orin.local` | `orin` |
| MSI Windows laptop | `msi` | `msi.local` | `msi` |
| WSL2 distro on MSI | distro name, for example `dev` | on-demand through Windows | `wsl2-<name>` |

## Supported Paths

```text
spark -> orin
orin  -> spark

spark -> wsl2-<name>
orin  -> wsl2-<name>

wsl2-<name> -> spark
wsl2-<name> -> orin
```

WSL2-to-WSL2 peer checks are intentionally not part of CI. The `wsl2-<name>`
aliases are on-demand endpoints reached through Windows OpenSSH and `wsl.exe`,
not a resident WSL2 peer mesh.

## Workflows

| Workflow | Purpose |
| --- | --- |
| **Setup Shared SSH Store** | Initializes Spark's shared SSH store, symlinks Spark's local `.ssh`, and wires Orin to the same store. |
| **WSL2 Provision** | Imports a WSL2 distro from the configured template, runs `firstboot.sh`, mounts the shared store, writes the `wsl2-<name>` alias, and registers the distro in `WSL2_DISTROS`. |
| **WSL2 Verify SSH Topology** | Tests supported Spark, Orin, and WSL2 SSH paths. |
| **WSL2 Unprovision** | Unregisters a WSL2 distro and removes it from `WSL2_DISTROS`. |

Normal WSL2 provisioning sequence:

```text
Actions -> WSL2 Provision -> distro_name: dev  ssh_port: 2222
Actions -> WSL2 Verify SSH Topology
```

For multiple distros:

```text
Actions -> WSL2 Provision -> distro_name: dev   ssh_port: 2222
Actions -> WSL2 Provision -> distro_name: test  ssh_port: 2223
Actions -> WSL2 Verify SSH Topology
```

## Orin One-Time Prerequisites

Run these on the Orin host as `aaron` before the first **Setup Shared SSH Store**
run.

Restore SSH files if only `.bak` files exist from an older CIFS setup:

```bash
cp /home/aaron/.ssh/authorized_keys.bak /home/aaron/.ssh/authorized_keys 2>/dev/null || touch /home/aaron/.ssh/authorized_keys
cp /home/aaron/.ssh/config.bak /home/aaron/.ssh/config 2>/dev/null || true
cp /home/aaron/.ssh/known_hosts.bak /home/aaron/.ssh/known_hosts 2>/dev/null || true
chmod 600 /home/aaron/.ssh/authorized_keys /home/aaron/.ssh/config /home/aaron/.ssh/known_hosts 2>/dev/null || true
```

Self-authorize Orin's own key so `HOST_SSH_KEY` can SSH to localhost:

```bash
grep -qF "$(cat /home/aaron/.ssh/id_ed25519.pub)" /home/aaron/.ssh/authorized_keys \
  || cat /home/aaron/.ssh/id_ed25519.pub >> /home/aaron/.ssh/authorized_keys
```

All machines share Spark's SSH identity via the shared store — `HOST_SSH_KEY` is already set as a GitHub secret from that key.

## Current Known-Good Commands

Replace `<name>` with the active WSL2 distro name, for example `dev`.

From DGX:

```bash
ssh orin hostname
ssh wsl2-<name> hostname
```

From Orin:

```bash
ssh spark hostname
ssh wsl2-<name> hostname
```

From WSL2:

```bash
ssh spark hostname
ssh orin hostname
```

From MSI Windows PowerShell:

```powershell
ssh wsl2-<name> hostname
```

BatchMode check:

```bash
ssh -o BatchMode=yes wsl2-<name> hostname
```

## Direct Ports

Each WSL2 distro still has a unique direct sshd port for provisioning readiness
checks and manual diagnostics:

```text
dev  -> 2222
test -> 2223
```

Do not use direct ports as the normal Spark/Orin access path. Normal access uses
the generated `wsl2-<name>` alias.

Probe candidate ports before adding a distro:

```powershell
cd path\to\miramar-platform-gcp\wsl2
.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299
```

## Bitvise Tunnel Configuration

Create one Bitvise SSH profile per machine. The SSH connection for both profiles uses port 22. The tunnel rows below go in the **C2S** (client-to-server) forwarding tab.

### DGX (spark-79b7.local — 192.168.1.200)

| Listen interface | Port | Destination host | Port | Comment |
|---|---|---|---|---|
| `127.0.0.1` | `8001` | `127.0.0.1` | `8001` | K8s dashboard |
| `127.0.0.1` | `8888` | `127.0.0.1` | `8888` | JupyterLab |
| `127.0.0.1` | `5000` | `127.0.0.1` | `5000` | MLflow |
| `127.0.0.1` | `8080` | `127.0.0.1` | `8080` | KFP UI |
| `127.0.0.1` | `8082` | `127.0.0.1` | `8082` | NeMo / NIM |
| `127.0.0.1` | `8890` | `127.0.0.1` | `8890` | KFP API |
| `127.0.0.1` | `11434` | `127.0.0.1` | `11434` | Ollama |
| `127.0.0.1` | `6333` | `127.0.0.1` | `6333` | Qdrant REST |
| `127.0.0.1` | `6334` | `127.0.0.1` | `6334` | Qdrant gRPC |

### AGX (orin.local — 192.168.1.202)

Local ports are offset so both profiles can run simultaneously without conflicts.

| Listen interface | Port | Destination host | Port | Comment |
|---|---|---|---|---|
| `127.0.0.1` | `8002` | `127.0.0.1` | `8001` | K8s dashboard |
| `127.0.0.1` | `8887` | `127.0.0.1` | `8888` | JupyterLab |
| `127.0.0.1` | `5001` | `127.0.0.1` | `5000` | MLflow |
| `127.0.0.1` | `8081` | `127.0.0.1` | `8080` | KFP UI |
| `127.0.0.1` | `8083` | `127.0.0.1` | `8082` | NeMo / NIM |
| `127.0.0.1` | `8891` | `127.0.0.1` | `8890` | KFP API |
| `127.0.0.1` | `11435` | `127.0.0.1` | `11434` | Ollama |
| `127.0.0.1` | `6335` | `127.0.0.1` | `6333` | Qdrant REST |
| `127.0.0.1` | `6336` | `127.0.0.1` | `6334` | Qdrant gRPC |

## Troubleshooting

### `ssh wsl2` Opens the MSI Windows Shell

Cause: `ssh wsl2` is hitting Windows OpenSSH on port `22`.

Fix: use the generated distro alias:

```bash
ssh wsl2-<name> hostname
```

Do not add a generic `Host wsl2` block for normal operation.

### `ssh wsl2-<name>` Asks for a Password

Likely causes:

- `/home/aaron/shared/ssh` was not mounted before `sshd -i` performed public-key
  authentication.
- `/home/aaron/shared/ssh/authorized_keys` does not contain Spark's public key.
- The `wsl2-<name>` alias in `/home/aaron/shared/ssh/config` is stale.

Fix:

```text
Actions -> Setup Shared SSH Store
Actions -> WSL2 Provision -> distro_name: <name>  ssh_port: <port>
Actions -> WSL2 Verify SSH Topology
```

Do not replace `/home/aaron/.ssh/authorized_keys` inside WSL2 with a local file.
It should be a symlink to:

```text
/home/aaron/shared/ssh/authorized_keys
```

### WSL2 Distro Is `Stopped`

This is expected when no Windows-side `wsl.exe` client is attached. The next
supported SSH connection through `wsl2-<name>` should start the distro on
demand.

### `ssh: Could not resolve hostname orin.local`

Inside WSL2, verify mDNS support:

```bash
getent hosts orin.local
getent hosts spark-79b7.local
getent hosts msi.local
```

If missing, rerun WSL2 provisioning. For manual diagnostics inside the distro:

```bash
sudo apt update
sudo apt install -y avahi-daemon libnss-mdns
sudo systemctl enable --now avahi-daemon
sudo sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
sudo systemctl restart avahi-daemon
sudo systemctl restart systemd-resolved 2>/dev/null || true
```

### Windows Firewall Command Fails

Cause: the command was not run from Administrator PowerShell.

For normal provisioning, let **WSL2 Provision** open the firewall rule. For
manual diagnostics, open Administrator PowerShell and rerun the firewall command
for the distro's direct sshd port.

### WSL2-to-WSL2 Peer Check Fails

That path is unsupported in CI. Do not add WSL2-to-WSL2 checks back to
`verify-ssh-topology.yaml`.

## End State

```text
DGX  -> ssh wsl2-<name> -> WSL2 distro Linux shell through on-demand wsl.exe
Orin -> ssh wsl2-<name> -> WSL2 distro Linux shell through on-demand wsl.exe
WSL2 -> ssh spark       -> DGX / Spark
WSL2 -> ssh orin        -> Jetson Orin
WSL2 -> ssh msi         -> MSI Windows shell on port 22
```

SSH config, `known_hosts`, `authorized_keys`, and the shared identity are
managed centrally in `/home/aaron/shared/ssh/` on Spark.
