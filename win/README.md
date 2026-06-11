# Windows laptop tooling

Bitvise SSH Client profiles for forwarding local ports on the Windows laptop to the on-prem machines. Load a profile in Bitvise via **Profiles → Open profile**, then click **Log in** to bring up all tunnels at once.

## Profiles

| File | Target | Host |
|---|---|---|
| `dgx.tlp` | DGX Spark | `spark-79b7.local` / `192.168.1.200` |
| `agx.tlp` | AGX Orin | `orin.local` / `192.168.1.202` |

Both profiles connect as user `aaron` using the shared SSH key.

## Tunnel mappings

| Service | dgx.tlp (local) | agx.tlp (local) | Remote port |
|---|---|---|---|
| MLflow | `5000` | `5001` | `5000` |
| Kubernetes dashboard | `8001` | `8002` | `8001` |
| JupyterLab | `8888` | `8887` | `8888` |
| Ollama | `11434` | `11435` | `11434` |
| KFP UI | `8080` | `8081` | `8080` |
| NeMo / NIM | `8082` | `8083` | `8082` |
| KFP API | `8890` | `8891` | `8890` |
| Qdrant REST | `6333` | `6335` | `6333` |
| Qdrant gRPC | `6334` | `6336` | `6334` |

AGX ports are offset by +1 (or -1 for JupyterLab) so both profiles can run simultaneously without conflicts. Qdrant uses +2 offset on AGX since it occupies two consecutive ports.
