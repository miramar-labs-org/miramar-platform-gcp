# GPU Quota Request

GCP GPU capacity is separate from quota. `ZONE_RESOURCE_POOL_EXHAUSTED` means the physical
hardware is gone in that zone — quota won't fix it. The solution is to request quota in
additional regions so the cluster can be relocated when a zone is exhausted.

## Check current capacity first

```sh
./scripts/gcp/gke/find-gpu-capacity.sh
```

This probes all GPU types and zones in parallel and shows the cheapest available options
with ready-to-use GKE Expand GPU settings. Run this before requesting quota to confirm
which regions actually have hardware available.

## How to request quota

GCP quota increases are submitted through the Console — not by email or support ticket.

1. Go to **IAM & Admin → Quotas & system limits**:
   `https://console.cloud.google.com/iam-admin/quotas?project=miramar-platform`

2. Filter by metric name: `NVIDIA_T4_GPUS`

3. Check the regions you want (see recommended list below), set new limit to `1`

4. Click **Edit Quotas**, fill in contact info and justification, submit

5. Repeat for `PREEMPTIBLE_NVIDIA_T4_GPUS` (covers spot instances) in the same regions

Approval typically takes a few hours to 2 business days.

## Recommended regions

Request quota in 2–3 geographically spread regions so there's always a fallback:

| Region | Location |
|---|---|
| `us-east1` | South Carolina |
| `us-east4` | Northern Virginia |
| `us-west1` | Oregon |

## Justification text

Paste this into the justification field of the quota request form:

> We are running a single-GPU ML inference workload on GKE Standard using NVIDIA T4 GPUs
> (Triton Inference Server). Our cluster is currently in us-central1, which is experiencing
> sustained ZONE_RESOURCE_POOL_EXHAUSTED across all zones for T4 on-demand and spot instances.
> We are requesting a limit of 1 T4 GPU in each of the listed regions so we can relocate
> the cluster when our primary region is capacity-exhausted. The GPU is used transiently —
> provisioned for inference jobs and torn down when idle. Total concurrent GPU usage will
> never exceed 1.

## After quota is approved

1. Run `./scripts/gcp/gke/find-gpu-capacity.sh` to confirm available capacity in the new region
2. Update `gcp/terraform/terraform.tfvars`:
   ```hcl
   zone   = "<new-zone>"
   region = "<new-region>"
   ```
3. Update `gcp/terraform-gpu/gpu.tfvars`:
   ```hcl
   cluster_zone = "<new-zone>"
   region       = "<new-region>"
   ```
4. Commit and push, then run the workflow sequence:
   **GKE Restore GPU → Miramar Platform Destroy → Miramar Platform Create → GKE Expand GPU**
