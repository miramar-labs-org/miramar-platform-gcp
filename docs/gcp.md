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

| Secret | Scope |
| --- | --- |
| `WIF_PROVIDER` | org-level secret |
| `GCP_SERVICE_ACCOUNT` | repo-level secret |

## Terraform Roots

| Root | Purpose | State |
| --- | --- | --- |
| `gcp/terraform/` | GKE cluster, default node pool, Artifact Registry | `gs://miramar-platform-cluster-state/terraform/state/` |
| `gcp/terraform-gpu/` | Temporary GPU node pool only | `gs://miramar-platform-cluster-state/terraform/gpu-state/` |

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

| Bucket | Purpose |
| --- | --- |
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

## GCP Scripts

| Script | Purpose |
| --- | --- |
| `gcp/bootstrap-miramar-platform.zsh` | One-time project, WIF, SA, IAM bootstrap |
| `gcp/create-miramar-platform.zsh` | Kubernetes namespaces, quotas, RBAC, AR IAM |
| `gcp/list-miramar-platform.zsh` | Enumerate live project resources |
| `scripts/gcp/resources.sh` | Enumerate live GCP resources |
| `scripts/gcp/create-bucket.sh` | Create GCS buckets idempotently |
| `scripts/gcp/gke/find-gpu-capacity.sh` | Probe real GPU capacity across zones |
