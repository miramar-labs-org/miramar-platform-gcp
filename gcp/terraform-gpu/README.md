# gcp/terraform-gpu — Transient GPU node pool

[Terraform](https://www.terraform.io) ([docs](https://developer.hashicorp.com/terraform/docs)) manages a single [CUDA](https://developer.nvidia.com/cuda-toolkit)-enabled GPU node pool attached to the existing [GKE](https://cloud.google.com/kubernetes-engine) `miramar-shared-gke` cluster. This module is **separate from `gcp/terraform/`** and has its own state — the two must never share state or be applied together.

## What this module provisions

| Resource                   | Notes                                                         |
| -------------------------- | ------------------------------------------------------------- |
| GPU node pool (`gpu-pool`) | Attached to the existing cluster; 1 node; `pd-standard` 50 GB |

The cluster itself is **not** managed here. This module reads the cluster name and zone as variables and assumes the cluster already exists.

## Why a separate module

The GPU pool is transient — it is added before a GPU workload and destroyed after. Keeping it in a separate Terraform root module with its own state means:

- `terraform destroy` here only removes the GPU pool, not the cluster
- No risk of state lock conflicts with the main module during concurrent workflows
- The **GKE Expand GPU** and **GKE Restore GPU** workflows can run independently

## State

Stored in GCS at `gs://miramar-platform-cluster-state/terraform/gpu-state/` — separate from the main module's `terraform/state/`.

```sh
terraform init -backend-config="bucket=miramar-platform-cluster-state"
```

## Variables

| Variable           | Example              | Purpose                                |
| ------------------ | -------------------- | -------------------------------------- |
| `project_id`       | `miramar-platform`   | GCP project                            |
| `region`           | `us-central1`        | Region                                 |
| `cluster_name`     | `miramar-shared-gke` | Target cluster (must pre-exist)        |
| `cluster_zone`     | `us-central1-b`      | Zone of the cluster                    |
| `gpu_machine_type` | `n1-standard-4`      | Node machine type                      |
| `gpu_type`         | `nvidia-tesla-t4`    | GPU accelerator type                   |
| `spot`             | `false`              | Use Spot VMs (cheaper but preemptible) |

Config in `gpu.tfvars`. The **Find GPU Capacity** workflow outputs ready-to-use values for `gpu_machine_type` and `gpu_type` based on live GCP quota.

## Outputs

| Output          | Value                     |
| --------------- | ------------------------- |
| `gpu_pool_name` | Name of the GPU node pool |

## Usage

This module is invoked exclusively by the **GKE Expand GPU** and **GKE Restore GPU** GitHub Actions workflows. To run locally:

```sh
cd gcp/terraform-gpu
terraform init -backend-config="bucket=miramar-platform-cluster-state"
terraform plan  -var-file=gpu.tfvars   # add pool
terraform apply -var-file=gpu.tfvars
terraform destroy -var-file=gpu.tfvars  # remove pool
```

## References

| Technology                                        | GitHub                                                        | Docs                                                    |
| ------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------- |
| [Terraform](https://www.terraform.io)             | [hashicorp/terraform](https://github.com/hashicorp/terraform) | [docs](https://developer.hashicorp.com/terraform/docs)  |
| [GKE](https://cloud.google.com/kubernetes-engine) | —                                                             | [docs](https://cloud.google.com/kubernetes-engine/docs) |
| [CUDA](https://developer.nvidia.com/cuda-toolkit) | —                                                             | [docs](https://docs.nvidia.com/cuda/)                   |

## Typical lifecycle

1. Run **Find GPU Capacity** to identify an available GPU type and zone.
2. Update `gpu.tfvars` with the chosen `gpu_machine_type` and `gpu_type`.
3. Run **GKE Expand GPU** — runs `terraform apply` here.
4. Deploy GPU workload.
5. Run **GKE Restore GPU** — runs `terraform destroy` here, removing the pool and stopping GPU billing.
