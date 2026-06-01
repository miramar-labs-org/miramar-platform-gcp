# Qdrant

[Qdrant](https://qdrant.tech) ([docs](https://qdrant.tech/documentation/)) — vector database deployed into the `qdrant-system` namespace on minikube. Used as the vector store for RAG pipelines.

Managed via the **Qdrant Deploy** / **Qdrant Undeploy** GHA workflows. Manual scripts below are for diagnostics and local iteration.

## Endpoints

| Interface | URL |
|---|---|
| REST API + Web UI | `http://localhost:6333` |
| Web UI dashboard | `http://localhost:6333/dashboard` |
| gRPC | `localhost:6334` |

Access requires the `qdrant-portfwd` systemd service (installed via `dgx/systemd/install.sh`) and an SSH tunnel from the laptop (`-L 6333:localhost:6333 -L 6334:localhost:6334`).

## Scripts

```sh
# Deploy Qdrant (idempotent — safe to re-run)
bash integrate-qdrant.sh

# Verify REST and gRPC endpoints are reachable
bash verify-qdrant-endpoints.sh

# Remove Qdrant (deletes namespace, PVC, and all data)
bash destroy-qdrant.sh
```

## Python client

```python
from qdrant_client import QdrantClient

client = QdrantClient(host="localhost", port=6333)
print(client.get_collections())
```

## Storage

PVC: `qdrant-pvc` — 20 Gi, `standard` StorageClass (minikube VM disk). Data persists across pod restarts but not across `destroy-qdrant.sh` runs.
