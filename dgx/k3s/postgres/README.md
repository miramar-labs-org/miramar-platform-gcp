# Postgres

[PostgreSQL 16](https://www.postgresql.org/) (`postgres:16-alpine`) — shared relational database deployed into the `postgres-system` namespace on k3s. Used by consumer apps (e.g. `multi-agent-ai-trader`) that need durable, queryable storage beyond what Slack/logs provide.

Managed via the **Postgres Deploy** / **Postgres Undeploy** GHA workflows. Manual scripts below are for diagnostics and local iteration.

Unlike Qdrant/MLflow, Postgres has **no laptop SSH tunnel / portfwd service** for now — `kubectl exec -it` + `psql` is sufficient for ad hoc inspection. Add a `postgres-portfwd` systemd service later if a GUI client from the laptop becomes worthwhile.

## Endpoint

| Interface           | Address                                              |
| -------------------- | ----------------------------------------------------- |
| Postgres (in-cluster) | `postgres.postgres-system.svc.cluster.local:5432`     |

## Scripts

```sh
# Deploy Postgres (idempotent — safe to re-run). Also provisions a consumer
# database/role if POSTGRES_CONSUMER_DB and POSTGRES_CONSUMER_USER are set.
POSTGRES_CONSUMER_DB=multi_agent_ai_trader \
POSTGRES_CONSUMER_USER=multi_agent_ai_trader \
bash integrate-postgres.sh

# Verify the pod is Ready, the Service has endpoints, and pg_isready succeeds
bash verify-postgres-endpoints.sh

# Remove Postgres (Deployment/Service/PVC only — the PV and its hostPath data
# survive, matching Retain policy; pass DELETE_NS=true to also drop the namespace)
bash destroy-postgres.sh
```

## Ad hoc access

```sh
kubectl -n postgres-system exec -it deploy/postgres -- psql -U postgres
```

Superuser password is stored in the `postgres-superuser` Secret (`postgres-system` namespace, key `POSTGRES_PASSWORD`), generated once on first deploy and reused on every subsequent `integrate-postgres.sh` run.

## Adding a new consumer

Re-run `integrate-postgres.sh` with `POSTGRES_CONSUMER_DB` / `POSTGRES_CONSUMER_USER` set for the new app (optionally `POSTGRES_CONSUMER_PASSWORD` to pin it, otherwise one is generated). The script prints a `DATABASE_URL` — paste that into the consumer app's own secret; it is not stored anywhere else. Re-running for an existing consumer is safe: the database/role/grants are idempotent and an existing role's password is left untouched.

## Storage

PV: `postgres-pv` (hostPath, default `~/shared/postgres-data` on the host) — `persistentVolumeReclaimPolicy: Retain`, `storageClassName: ""` (k3s has no dynamic provisioner). Data persists across pod restarts and across `destroy-postgres.sh` runs (unless the host directory is manually removed).
