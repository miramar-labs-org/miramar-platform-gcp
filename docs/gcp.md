# GCP Operations

GCP resources live in project `miramar-platform`. Workflows authenticate through
Workload Identity Federation, so there are no long-lived service account keys.

## Bootstrap

Run locally once with an active `gcloud` session:

```sh
zsh ./gcp/bootstrap-miramar-platform.zsh 2>&1 | tee /tmp/bootstrap.log
```

The script creates the project, links billing, enables APIs, creates the WIF
pool/provider, creates service accounts, and applies IAM bindings. It prints:

| Secret                | Scope             |
| --------------------- | ----------------- |
| `WIF_PROVIDER`        | org-level secret  |
| `GCP_SERVICE_ACCOUNT` | repo-level secret |

## Terraform Roots

| Root                 | Purpose                                           | State                                                      |
| -------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| `gcp/terraform/`     | GKE cluster, default node pool, Artifact Registry | `gs://miramar-platform-cluster-state/terraform/state/`     |
| `gcp/terraform-gpu/` | Temporary GPU node pool only                      | `gs://miramar-platform-cluster-state/terraform/gpu-state/` |

After editing `gcp/terraform/terraform.tfvars`, sync GitHub org variables:

```sh
./scripts/gha/sync-github-tf-vars.sh
```

## Workload Identity Federation

Resources:

- Pool: `projects/808481995423/locations/global/workloadIdentityPools/github-actions`
- Provider: `github`
- Issuer: `https://token.actions.githubusercontent.com`
- Service account: `gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com`

Expected provider condition:

```text
attribute.repository_owner=='miramar-labs-org'
```

Expected service account principal:

```text
principalSet://iam.googleapis.com/projects/808481995423/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/miramar-labs-org
```

If WIF auth fails with `iam.serviceAccounts.getAccessToken` denied, verify the
service account IAM binding matches the current GitHub org exactly.

## Storage

All buckets are in `us-central1`.

| Bucket                           | Purpose                                                  |
| -------------------------------- | -------------------------------------------------------- |
| `miramar-platform-cluster-state` | Terraform state, GPU pool state, GKE node pool snapshots |

The state bucket is created before `terraform init` and is not managed by the
same Terraform config that uses it as a backend.

Manual bucket creation:

```sh
./scripts/gcp/create-bucket.sh \
  --bucket <name> \
  --project miramar-platform \
  --location us-central1
```

## Gateway API

External HTTPS exposure for GKE-hosted serving workloads via the Kubernetes Gateway API.
The Gateway always routes to the GKE model router, which routes to whichever serving
backend is currently deployed. There is only ever one model on GKE at a time.

**Architecture:**
```
https://api.miramar-labs.com/v1
  → GKE Gateway  (gke-l7-global-external-managed)
    → GKE Model Router  (model-router.model-router.svc.cluster.local:8000)
      → GKE Serving Backend  (vLLM / NIM / TRT-LLM)
```

**Static resources** (created by `GCP Platform Create`, deleted by `GCP Platform Destroy`):

| Resource | Name | Notes |
|---|---|---|
| Global static IP | `miramar-gateway-ip` | ~$3/mo; DNS record set once and stays |
| Managed SSL cert | `miramar-api-cert` | Free; covers `api.miramar-labs.com` |

**One-time DNS setup** (manual, after first `GCP Platform Create`):

The static IP is printed in the `GCP Platform Create` job summary. Create one A record
in GoDaddy's DNS dashboard:

1. Log in → **My Products → miramar-labs.com → DNS** (or `dcc.godaddy.com`)
2. Click **Add New Record**
3. Fill in:
   - **Type:** `A`
   - **Name:** `api`  *(GoDaddy appends `.miramar-labs.com` automatically)*
   - **Value:** the static IP from the job summary
   - **TTL:** `600` (10 min; GoDaddy's default 1 hour also works)
4. Save

Verify propagation (typically 5–30 min via GoDaddy):

```sh
dig api.miramar-labs.com
```

Once the IP resolves, the ACME challenge runs and the SSL cert becomes ACTIVE within
10–60 minutes. All subsequent Gateway deploys re-attach the existing cert instantly.

This record is permanent — it survives Gateway deploy/undeploy cycles.

**Cost:** ~$0.025/hr (~$18/mo) while the Gateway is deployed (GCP Global HTTP(S) LB
forwarding rule). Static IP and cert are retained on undeploy so the next deploy is instant.
Treat the Gateway as transient — deploy it alongside a serving workload, undeploy it when done.

**SSL cert provisioning:** first deploy takes 10–60 minutes after DNS resolves (ACME challenge).
All subsequent deploys re-attach the existing cert — no wait.

**Workflows:**

| Workflow | Purpose |
|---|---|
| `deploy-gke-gateway.yaml` | Apply Gateway + HTTPRoute; set `GKE_GATEWAY_URL`; check cert status |
| `undeploy-gke-gateway.yaml` | Delete Gateway + HTTPRoute; stop LB billing; clear `GKE_GATEWAY_URL` |

Both workflows support `workflow_call` so GKE serving deploy/undeploy workflows can
wire the Gateway automatically. Also available as `workflow_dispatch` for manual use.

**Typical session:**

```
GKE Expand GPU
  → Model Router Deploy (runner=gke)
  → [GKE serving deploy]  → auto-calls GKE Gateway Deploy
  → curl https://api.miramar-labs.com/v1/models
  → [GKE serving undeploy]  → auto-calls GKE Gateway Undeploy
  → Model Router Undeploy (runner=gke)
  → GKE Restore GPU
```

**GKE model router config:** `gke/model-router/litellm-config.yaml` — updated automatically
by GKE serving deploy/undeploy workflows (same auto-registration pattern as DGX/AGX).

## GCP Scripts

| Script                                 | Purpose                                     |
| -------------------------------------- | ------------------------------------------- |
| `gcp/bootstrap-miramar-platform.zsh`   | One-time project, WIF, SA, IAM bootstrap    |
| `gcp/create-miramar-platform.zsh`      | Kubernetes namespaces, quotas, RBAC, AR IAM |
| `gcp/list-miramar-platform.zsh`        | Enumerate live project resources            |
| `scripts/gcp/resources.sh`             | Enumerate live GCP resources                |
| `scripts/gcp/create-bucket.sh`         | Create GCS buckets idempotently             |
| `scripts/gcp/gke/find-gpu-capacity.sh` | Probe real GPU capacity across zones        |
