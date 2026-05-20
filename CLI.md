# CLI Reference

Useful commands for working with the Miramar platform. All GCP commands assume project `miramar-platform` and region/zone `us-west1` / `us-west1-a` unless noted.

---

## GitHub CLI (`gh`)

```sh
# Authenticate
gh auth login
gh auth status

# List workflow runs for this repo
gh run list --repo miramar-labs-org/miramar-platform-gcp

# Watch a running workflow
gh run watch --repo miramar-labs-org/miramar-platform-gcp

# Trigger a workflow manually
gh workflow run gke-expand-triton.yaml --repo miramar-labs-org/miramar-platform-gcp \
  --field namespace=mlops-torch-triton-gke-pipeline \
  --field machine_type=n1-standard-4 \
  --field gpu_type=nvidia-tesla-t4

# View workflow run logs
gh run view <run-id> --log --repo miramar-labs-org/miramar-platform-gcp

# List self-hosted runners
gh api /orgs/miramar-labs-org/actions/runners | jq '.runners[] | {name,status,labels: [.labels[].name]}'

# List org-level variables
gh variable list --org miramar-labs-org

# List org-level secrets (names only)
gh secret list --org miramar-labs-org

# Set an org variable
gh variable set MY_VAR --org miramar-labs-org --body "value"

# Cancel all queued/in-progress runs
./scripts/gha/flush-queues.sh
```

---

## gcloud

### Auth

```sh
gcloud auth login
gcloud auth application-default login
gcloud config set project miramar-platform
gcloud auth list
```

### GKE

```sh
# Refresh kubeconfig (or use the script)
gcloud container clusters get-credentials miramar-shared-gke \
  --zone us-west1-a --project miramar-platform
./scripts/gcp/gke/get-credentials.sh

# List clusters
gcloud container clusters list --project miramar-platform

# Describe a cluster
gcloud container clusters describe miramar-shared-gke \
  --zone us-west1-a --project miramar-platform

# List node pools
gcloud container node-pools list \
  --cluster miramar-shared-gke --zone us-west1-a --project miramar-platform

# Describe a node pool
gcloud container node-pools describe default-pool \
  --cluster miramar-shared-gke --zone us-west1-a --project miramar-platform
```

### Artifact Registry

```sh
# List repositories
gcloud artifacts repositories list --location us-west1 --project miramar-platform

# List images in the apps repo
gcloud artifacts docker images list us-west1-docker.pkg.dev/miramar-platform/apps

# Configure docker auth for GAR
gcloud auth configure-docker us-west1-docker.pkg.dev
```

### IAM & WIF

```sh
# List service accounts
gcloud iam service-accounts list --project miramar-platform

# Show WIF attribute condition
gcloud iam workload-identity-pools providers describe github \
  --project miramar-platform \
  --location global \
  --workload-identity-pool github-actions \
  --format="value(attributeCondition)"

# Show SA IAM bindings
gcloud iam service-accounts get-iam-policy \
  gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com \
  --project miramar-platform --format json
```

### Compute / GPU

```sh
# List GPU types available in a zone
gcloud compute accelerator-types list --filter="zone:(us-west1-a)" \
  --format="table(name,zone)"

# List machine types with GPU support
gcloud compute machine-types list --filter="zone:(us-west1-a) AND name~g2" \
  --format="table(name,guestCpus,memoryMb)"
```

### GCS

```sh
# List buckets
gsutil ls -p miramar-platform

# View Terraform state files
gsutil ls gs://miramar-platform-cluster-state/terraform/

# View GKE snapshots
gsutil ls gs://miramar-platform-cluster-state/gke/

# Copy a file
gsutil cp gs://miramar-platform-cluster-state/gke/quota-mlops-torch-triton-gke-pipeline.json /tmp/

# Delete a file
gsutil rm gs://miramar-platform-cluster-state/gke/quota-mlops-torch-triton-gke-pipeline.json
```

---

## Terraform

### Main cluster module (`gcp/terraform/`)

```sh
cd gcp/terraform

# Init (bucket must exist first)
terraform init -backend-config="bucket=miramar-platform-cluster-state"

# Plan
terraform plan -var-file=terraform.tfvars

# Apply
terraform apply -var-file=terraform.tfvars

# Apply with node count override (expand/restore)
terraform apply -var-file=terraform.tfvars -var="node_pool_count=2"

# Destroy
terraform destroy -var-file=terraform.tfvars

# Show current state
terraform show

# List resources in state
terraform state list

# Refresh state from live GCP
terraform refresh -var-file=terraform.tfvars
```

### GPU node pool module (`gcp/terraform-gpu/`)

```sh
cd gcp/terraform-gpu

terraform init -backend-config="bucket=miramar-platform-cluster-state"

# Create GPU pool (overrides apply to gpu_type / gpu_machine_type)
terraform apply -var-file=gpu.tfvars \
  -var="gpu_type=nvidia-tesla-t4" \
  -var="gpu_machine_type=n1-standard-4"

# Destroy GPU pool
terraform destroy -var-file=gpu.tfvars

# Check if pool exists in state
terraform show -json | python3 -c \
  "import json,sys; r=json.load(sys.stdin).get('values',{}).get('root_module',{}).get('resources',[]); print('pool exists' if r else 'no pool in state')"
```

---

## kubectl

### Cluster

```sh
# Current context
kubectl config current-context

# List all contexts
kubectl config get-contexts

# List nodes with labels
kubectl get nodes --show-labels

# Watch node status
kubectl get nodes -w
```

### Namespaces & Quotas

```sh
# List namespaces
kubectl get namespaces

# Describe resource quota for a namespace
kubectl describe resourcequota namespace-quota -n mlops-torch-triton-gke-pipeline

# Patch quota manually (e.g. for GPU workloads)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: mlops-torch-triton-gke-pipeline
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "10"
    requests.nvidia.com/gpu: "1"
    limits.nvidia.com/gpu: "1"
EOF
```

### Pods

```sh
# List pods in a namespace
kubectl get pods -n mlops-torch-triton-gke-pipeline

# Watch pods
kubectl get pods -n mlops-torch-triton-gke-pipeline -w

# Describe a pod (events, resource requests, scheduling errors)
kubectl describe pod <pod-name> -n mlops-torch-triton-gke-pipeline

# Logs
kubectl logs <pod-name> -n mlops-torch-triton-gke-pipeline
kubectl logs <pod-name> -n mlops-torch-triton-gke-pipeline --previous   # crashed container
kubectl logs <pod-name> -n mlops-torch-triton-gke-pipeline -f           # follow

# Delete a pod (ReplicaSet will recreate it)
kubectl delete pod <pod-name> -n mlops-torch-triton-gke-pipeline

# Exec into a pod
kubectl exec -it <pod-name> -n mlops-torch-triton-gke-pipeline -- /bin/bash
```

### Services & Port Forwarding

```sh
# List services (no LoadBalancers — use port-forward for local access)
kubectl get svc -n mlops-torch-triton-gke-pipeline

# Forward Triton HTTP port
kubectl port-forward svc/triton 8000:8000 -n mlops-torch-triton-gke-pipeline

# Forward Triton gRPC port
kubectl port-forward svc/triton 8001:8001 -n mlops-torch-triton-gke-pipeline

# Forward Triton metrics port
kubectl port-forward svc/triton 8002:8002 -n mlops-torch-triton-gke-pipeline
```

### GPU

```sh
# Check GPU allocatable on nodes
kubectl get nodes -o json | python3 -c \
  "import json,sys; [print(n['metadata']['name'], n['status'].get('allocatable',{}).get('nvidia.com/gpu','0')) for n in json.load(sys.stdin)['items']]"

# Check if NVIDIA device plugin DaemonSet is running
kubectl get daemonset nvidia-driver-installer -n kube-system
```
