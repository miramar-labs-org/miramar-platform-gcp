# gcp/terraform — GKE cluster + Artifact Registry

Manages the core GCP infrastructure for the Miramar platform: a GKE Standard cluster, a default node pool, and an Artifact Registry repository.

## What this module provisions

| Resource | Name | Notes |
|---|---|---|
| GKE Standard cluster | `miramar-shared-gke` | VPC-native, REGULAR release channel, deletion protection off |
| Default node pool | `default-pool` | `e2-medium`, `pd-standard` 30 GB, single node |
| Artifact Registry repo | `apps` | Docker format, `us-central1` |

## What this module does NOT manage

**IAM and Workload Identity Federation are intentionally outside Terraform.** They are bootstrapped once by `gcp/bootstrap-miramar-platform.zsh` and are stable enough that putting them in Terraform would add churn for no benefit. Do not add them here.

The GPU node pool is also out of scope — it lives in `gcp/terraform-gpu/` with its own state.

## State

Stored in GCS at `gs://miramar-platform-cluster-state/terraform/state/`. The bucket itself is created by the bootstrap script and is not managed by Terraform (bootstrapping the state backend from within itself is a chicken-and-egg problem).

```sh
terraform init -backend-config="bucket=miramar-platform-cluster-state"
```

## Design decisions

**`remove_default_node_pool = true` + separate `google_container_node_pool`**
GKE creates an unmanaged default node pool at cluster creation time. Removing it and re-creating it as a managed resource gives Terraform full lifecycle control (count, machine type, disk size) without forcing a cluster replacement on every change.

**VPC-native networking (`networking_mode = "VPC_NATIVE"`)**
Required for GKE features like alias IPs and private clusters. The default routes-based networking mode is legacy and being deprecated.

**`deletion_protection = false`**
This is a dev/experimental platform. Deletion protection would block `terraform destroy` in the **Miramar Platform Destroy** workflow, which needs to tear down cleanly.

**Cost constraints — do not change without discussion**
- Machine type: `e2-medium` (shared-core, cheapest viable node)
- Disk: `pd-standard` (HDD, not SSD — lower cost)
- Node count: 1 (scale via **GKE Expand** workflow, not by changing `node_pool_count` here)
- No `LoadBalancer` services, no Cloud NAT, no regional cluster

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `project_id` | `miramar-platform` | GCP project |
| `region` | `us-central1` | Region for AR and cluster |
| `zone` | `us-central1-b` | Zone for the node pool |
| `cluster_name` | `miramar-shared-gke` | GKE cluster name |
| `ar_repo` | `apps` | Artifact Registry repo name |
| `node_pool_count` | `1` | Node count — treat as read-only; use GKE Expand/Restore workflows to change it |

**Source of truth:** `terraform.tfvars`. GitHub org variables are synced from it via `scripts/gha/sync-github-tf-vars.sh`. Never edit GitHub variables directly.

## Outputs

| Output | Value |
|---|---|
| `cluster_name` | Cluster name |
| `cluster_location` | Zone |
| `node_pool_name` | `default-pool` |
| `node_pool_count` | Current node count |
| `ar_repository` | `{region}-docker.pkg.dev/{project_id}/{ar_repo}` |

## Usage

```sh
cd gcp/terraform
terraform init -backend-config="bucket=miramar-platform-cluster-state"
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Normally run via the **Miramar Platform Create** and **Miramar Platform Destroy** GitHub Actions workflows, not locally.
