# NeMo on GKE

## How to use it:

    export TF_VAR_project_id="YOUR_PROJECT"
    terraform init
    terraform apply

Then connect:

    gcloud container clusters get-credentials nemo-gke --region us-central1 --project YOUR_PROJECT
    kubectl get nodes -o wide

If you used the taint, NeMo pods must tolerate it (your Helm values will need tolerations like key: nemo, operator: Equal, value: reserved, effect: NoSchedule).

## Picking the right GPU on GCP (important)

NeMo’s beginner tutorial lists B200 / A100 80GB / H100 80GB class parts. 
[NVIDIA Docs](https://docs.nvidia.com/nemo/microservices/25.12.0/get-started/setup/requirements.html?utm_source=chatgpt.com)

On GCP those typically map like this:

H100 80GB → accelerator type nvidia-h100-80gb (A3 High series) 
[Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/gpus/about-gpus?utm_source=chatgpt.com)

A100 80GB → accelerator type nvidia-a100-80gb (A2 Ultra series) 
[Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/gpus?utm_source=chatgpt.com)

You must pick a zone that actually has capacity for that GPU type (otherwise the node pool will fail to create).

[Google Cloud Documentation](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/gpus)

## Cheapest viable GCP shape
✅ A2 Ultra: a2-ultragpu-2g (2 × A100 80GB)

NeMo MS (and the tutorials) explicitly call for two of B200 180GB / A100 80GB / H100 80GB GPUs. 
[NVIDIA Docs](https://docs.nvidia.com/nemo/microservices/latest/requirements.html)

On GCP, A2 Ultra machine types are the ones that come with A100 80GB attached. 
[Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/gpus?utm_source=chatgpt.com)

**a2-ultragpu-2g** is exactly 2× A100 80GB. 
[Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/gpus?utm_source=chatgpt.com)

## What it costs (order-of-magnitude)

Google’s official public GPU pricing page doesn’t directly list the A2 Ultra per-hour rate (it even notes A2 Ultra committed pricing is via sales), so treat these as estimates you should confirm in the Pricing Calculator / console. 
[Google Cloud](https://cloud.google.com/compute/gpus-pricing)

That said, third-party aggregations consistently put:

**a2-ultragpu-2g** around ~$9–$12/hr on-demand depending on region 
[GCloud Compute](https://gcloud-compute.com/a2-ultragpu-2g.html?utm_source=chatgpt.com)

Spot around ~$4–$5/hr (but interruptible) 
[GCloud Compute](https://gcloud-compute.com/a2-ultragpu-2g.html?utm_source=chatgpt.com)

Plus:

GKE cluster management fee: $0.10/hr per cluster 
[Google Cloud](https://cloud.google.com/kubernetes-engine/pricing?utm_source=chatgpt.com)

You may get monthly free tier credits for GKE (depends on cluster type; check your billing account). 
[Google Cloud](https://cloud.google.com/kubernetes-engine?utm_source=chatgpt.com)

So: A2 Ultra on Spot is usually the cheapest way to “actually try the NeMo tutorial hardware profile” on GCP.

## How to run:

    export TF_VAR_project_id="YOUR_PROJECT_ID"
    terraform init
    terraform apply

Then:

    gcloud container clusters get-credentials nemo-a2ultra --zone us-central1-a --project YOUR_PROJECT_ID
    kubectl get nodes -o wide

## Next step you’ll almost certainly need (GPU enablement in Kubernetes)

After the node is up, you typically install:

NVIDIA device plugin

NVIDIA driver installer (if not using GKE’s managed driver path)

GKE docs recommend automatic driver installation, but the best method varies by image/cluster version and whether you specify GPU accelerators vs accelerator-optimized machine types.

If you paste:

- kubectl version --short

- kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}{"\n"}'

- kubectl describe node <node> | grep -i nvidia -n (or just the full describe)

here are the copy/paste steps to make nvidia.com/gpu show up and run a GPU test Pod on your GKE Standard + COS_CONTAINERD node pool.

    Key idea: on GKE you either (a) get automatic driver install via GKE, or (b) you manually install drivers (COS driver-installer DaemonSet). If you don’t tell GKE to auto-install drivers, you must manually install them.

### Sanity checks (node exists + your GPU node is present)

    kubectl get nodes -o wide
    kubectl get pods -n kube-system | egrep -i "nvidia|gpu|device-plugin|driver" || true

Also check whether the node has the “GPU node” label GKE uses:

    NODE="$(kubectl get nodes -o name | head -n1)"
    kubectl get "$NODE" --show-labels | tr ',' '\n' | egrep "cloud.google.com/gke-accelerator|cloud.google.com/gke-gpu-driver-version" || true

That cloud.google.com/gke-accelerator label is what the COS driver-installer DaemonSet selects for.

### If drivers aren’t installed yet: install them (COS)

This is the standard COS path:

    kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded-latest.yaml

That DaemonSet:

- targets nodes with cloud.google.com/gke-accelerator

- tolerates all taints (operator: Exists), so it still runs even if you tainted the node for NeMo. 
GitHub

Watch it come up:

    kubectl get pods -n kube-system --watch | egrep -i "nvidia|gpu|driver|device-plugin"

Google’s GPU Operator doc also shows how to verify the installer output via logs. [Google Cloud Docs](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/gpu-operator)

Verify installer logs:

    kubectl logs -n kube-system -l k8s-app=nvidia-driver-installer \
    -c nvidia-driver-installer --tail=-1

### Verify Kubernetes sees GPUs (this is the goal)

Once the driver + device plugin are ready, the node should advertise GPU capacity:

    kubectl describe node "${NODE#node/}" | egrep -n "Capacity:|Allocatable:|nvidia.com/gpu" -n

You want to see something like:

- nvidia.com/gpu: 2

If you don’t see nvidia.com/gpu, the device plugin isn’t running/ready yet.

### Run a GPU test Pod (with your NeMo taint tolerated)

This is the same CUDA “vectoradd” smoke test pattern, but with a toleration for your nemo=reserved:NoSchedule taint. 
[RAPIDS Docs](https://docs.rapids.ai/deployment/stable/cloud/gcp/gke/)

    cat << 'EOF' | kubectl apply -f -
    apiVersion: v1
    kind: Pod
    metadata:
    name: cuda-vectoradd
    spec:
    restartPolicy: OnFailure
    tolerations:
    - key: "nemo"
        operator: "Equal"
        value: "reserved"
        effect: "NoSchedule"
    containers:
    - name: cuda-vectoradd
        image: nvidia/samples:vectoradd-cuda11.6.0-ubuntu18.04
        resources:
        limits:
            nvidia.com/gpu: 1
    EOF

Then:

    kubectl get pod cuda-vectoradd -w
    kubectl logs cuda-vectoradd

If it runs and prints output successfully, your GPU stack is good.

### If the driver installer never schedules

The COS installer DaemonSet only schedules on nodes that have cloud.`google.com/gke-accelerator`. 
GitHub

So if your node doesn’t have that label, you have two good fixes:

#### Fix A (best): make the node pool explicitly GPU-aware (Terraform change)

GKE maps A2 Ultra to A100 80GB and the accelerator type `nvidia-a100-80gb`. 
[Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/gpus?utm_source=chatgpt.com)

And Terraform supports `gpu_driver_installation_config` under guest_accelerator. 
[GitHub](https://github.com/hashicorp/terraform-provider-google/issues/17972?utm_source=chatgpt.com)

In your `google_container_node_pool.gpu_pool.node_config`, add:

    guest_accelerator {
    type  = "nvidia-a100-80gb"
    count = 2

    gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT" # or "LATEST" on COS
    }
    }

Then terraform apply (this usually forces node recreation).

#### Fix B: Install NVIDIA GPU Operator instead

Google documents the NVIDIA GPU Operator option on GKE (supported on GKE Standard), including the Helm flags needed for COS driver/toolkit paths. 
Google Cloud Documentation

This is heavier, but gives a consistent “NVIDIA-managed” stack.

### One more important note (cost + stability)

If you set use_spot=true, your node can be preempted. That’s fine for experimentation, but it will interrupt long runs (fine-tuning especially).

If you paste the output of:

    kubectl get nodes --show-labels | head
    kubectl get pods -n kube-system | egrep -i "nvidia|gpu|driver|device-plugin"

…I’ll tell you immediately which branch you’re on (already good vs needs the guest_accelerator Terraform tweak).