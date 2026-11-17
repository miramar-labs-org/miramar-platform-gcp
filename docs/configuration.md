# Configuration Reference

GitHub Actions uses a mix of org secrets, repo secrets, org variables, and repo
variables. GCP variables are synced from `gcp/terraform/terraform.tfvars`; lab
host values are set manually.

## GitHub Secrets

### Org-Level Secrets

| Secret               | Value                                      | Purpose                                                                                            |
| -------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `WIF_PROVIDER`       | output of `bootstrap-miramar-platform.zsh` | WIF provider resource path shared by repos for GCP auth                                            |
| `HF_TOKEN`           | Hugging Face API token                     | Injected into KFP pods via `mlabs-api-keys` K8s secret; also used directly in workflow steps       |
| `NVIDIA_API_KEY`     | NVIDIA NGC API key                         | Required by NeMo Microservices and NIM workflows; also injected into KFP pods via `mlabs-api-keys` |
| `NGC_API_KEY`        | NVIDIA NGC API key (pipeline use)          | Injected into KFP pods via `mlabs-api-keys` K8s secret                                             |
| `OPENAI_API_KEY`     | OpenAI API key                             | Injected into KFP pods via `mlabs-api-keys` K8s secret. **Not** for LLM-as-judge — that is the local platform judge on the AGX (`docs/agx.md`); an external judge would breach the PHI boundary |
| `ANTHROPIC_API_KEY`  | Anthropic API key                          | Injected into KFP pods via `mlabs-api-keys` K8s secret                                             |
| `WANDB_API_KEY`      | Weights & Biases API key                   | Injected into KFP pods via `mlabs-api-keys` K8s secret                                             |
| `LANGCHAIN_API_KEY`  | LangChain / LangSmith API key              | Injected into KFP pods via `mlabs-api-keys` K8s secret                                             |
| `HOST_SSH_KEY`       | Private SSH key                            | SSH into DGX, AGX, or WSL2 hosts from runners (all machines share Spark's identity)                |
| `DGX_SMB_PASSWORD`   | Samba password for DGX `aaron`             | Used by **Setup Shared SSH Store**; not needed by WSL2 Provision                                   |
| `DGX_K3S_KUBECONFIG` | base64 kubeconfig                          | Written by **K3s Install** (runner=dgx); used by k3s workflows                                     |
| `AGX_K3S_KUBECONFIG` | base64 kubeconfig                          | Written by **K3s Install** (runner=agx) on first run                                               |

### Repo-Level Secrets

| Secret                     | Value                                                         | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GCP_SERVICE_ACCOUNT`      | `gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com` | Cluster-ops service account used by platform lifecycle workflows                                                                                                                                                                                                                                                                                                                                                                                                    |
| `WSL2_HOST_USER`           | Windows SSH user                                              | SSH login for WSL2 workflows                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `WSL2_HOST_SSH_KEY`        | Private SSH key                                               | SSH into Windows; public key must be authorized in Windows OpenSSH                                                                                                                                                                                                                                                                                                                                                                                                  |

## GitHub Variables

### Org-Level Variables

Sync GCP variables from Terraform after changing `gcp/terraform/terraform.tfvars`:

```sh
./scripts/gha/sync-github-tf-vars.sh
```

| Variable              | Value                              | Notes                                                                                      |
| --------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------ |
| `GCP_PROJECT_ID`      | `miramar-platform`                 | synced from tfvars                                                                         |
| `GKE_CLUSTER_NAME`    | `miramar-shared-gke`               | synced from tfvars                                                                         |
| `GKE_ZONE`            | `us-east1-b`                       | synced from tfvars                                                                         |
| `GCP_REGION`          | `us-east1`                         | synced from tfvars                                                                         |
| `GAR_REPO`            | `apps`                             | synced from tfvars                                                                         |
| `GKE_STATE_BUCKET`    | `miramar-platform-cluster-state`   | set manually                                                                               |
| `DGX_HOST_IP`         | `192.168.1.200`                    | static IP of DGX Spark                                                                     |
| `DGX_HOST_USER`       | `aaron`                            | SSH user on DGX                                                                            |
| `AGX_HOST_IP`         | `192.168.1.202`                    | static IP of AGX Orin                                                                      |
| `AGX_HOST_USER`       | `aaron`                            | SSH user on AGX                                                                            |
| `AGX_VRAM_USEABLE`    | `40`                               | GB available for AI models on AGX (64 GB total − 24 GB system)                             |
| `WSL2_HOST`           | `192.168.1.201`                    | static IP of Windows (MSI) machine — shared by all WSL2 distros                            |
| `MLFLOW_TRACKING_URI` | `http://host.docker.internal:5000` | MLflow endpoint inside runner containers (resolves to local host on both DGX and AGX)      |
| `QDRANT_URL`          | `http://host.docker.internal:6333` | Qdrant REST endpoint inside runner containers (resolves to local host on both DGX and AGX) |
| `DGX_VRAM_USEABLE`    | `100`                              | GB available for AI models on DGX (128 GB total − ~28 GB platform)                         |
| `DGX_DEFAULT_MODEL`   | `qwen3.6:35b-a3b`                  | default primary LLM for scaffolded projects; substituted into templates as `{{DGX_DEFAULT_MODEL}}` |
| `AGX_DEFAULT_MODEL`   | `phi4`                             | the shared platform judge; substituted into templates as `{{AGX_DEFAULT_MODEL}}`           |

`DGX_DEFAULT_MODEL` / `AGX_DEFAULT_MODEL` are set manually and are the platform's
two model defaults. **Create Project** substitutes them into a new project's
`config.yaml` at scaffold time, so changing the default for every future project
is a variable edit rather than a template commit. They are frozen into the
project at creation — an existing repo keeps whatever value it was scaffolded
with until it is re-scaffolded.

`DGX_DEFAULT_MODEL` must be an **Ollama tag cached on the DGX** (it is used as a
served model name, not a HuggingFace repo). It never replaces a template's
HuggingFace `model.id` — that is the model a fine-tune project trains, and an
Ollama tag cannot be LoRA-trained. `AGX_DEFAULT_MODEL` must be cached on the AGX
and fit the ~40 GB budget.

### Org-Level Active State Variables

Drive the green/red dashboard badges. Set by deploy workflows, cleared by undeploy workflows. Seed on fresh install with `gh api` PATCH→POST upserts using your interactive `gh` login.

| Variable            | Set to `true` by      | Set to `false` by               |
| ------------------- | --------------------- | ------------------------------- |
| `DGX_K3S_ACTIVE`    | K3s Install (dgx)     | K3s Uninstall (dgx)             |
| `DGX_NEMO_ACTIVE`   | NeMo Deploy (dgx)     | NeMo Undeploy (dgx)             |
| `DGX_MLFLOW_ACTIVE` | MLflow Deploy (dgx)   | MLflow Undeploy (dgx)           |
| `DGX_QDRANT_ACTIVE` | Qdrant Deploy (dgx)   | Qdrant Undeploy (dgx)           |
| `DGX_KFP_ACTIVE`    | Kubeflow Deploy (dgx) | Kubeflow Undeploy (dgx)         |
| `DGX_OLLAMA_ACTIVE`          | Ollama Deploy (dgx)                             | Ollama Undeploy (dgx), rollback |
| `AGX_OLLAMA_ACTIVE`          | Ollama Deploy (agx)                             | Ollama Undeploy (agx), rollback |
| `DGX_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy (dgx)                    | Nsight Operator Undeploy (dgx)  |
| `GKE_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy GKE; GCP Platform Create | Nsight Operator Undeploy GKE    |
| `GKE_GPU_POOL_ACTIVE`        | GKE Expand GPU                                  | GKE Restore GPU                 |

`AGX_OLLAMA_ACTIVE` is the only AGX badge the dashboard reads. The AGX runs
Ollama and nothing else ([agx.md](agx.md)), so `AGX_K3S_ACTIVE`,
`AGX_NEMO_ACTIVE`, `AGX_MLFLOW_ACTIVE`, `AGX_QDRANT_ACTIVE`, `AGX_KFP_ACTIVE`,
`AGX_NSIGHT_OPERATOR_ACTIVE` and `AGX_OPENWEBUI_ACTIVE` are unread. The
workflows still write them if you point one at `runner: agx`; nothing renders
the result.

### Repo-Level Variables

| Variable                     | Initial value | Purpose                                                         |
| ---------------------------- | ------------- | --------------------------------------------------------------- |
| `WSL2_DISTROS`               | `NONE`        | Active WSL2 distro names; updated by WSL2 Provision/Unprovision |
| `OLLAMA_VERSION`             | `—`           | Ollama binary version; written by Ollama Update                 |
| `CURRENT_NIM_MODEL`          | `none`        | NIM currently loaded on DGX                                     |
| `CURRENT_OLLAMA_MODEL`       | `none`        | Ollama model currently loaded on DGX                            |
| `CURRENT_NIM_VRAM_GB`        | `0`           | VRAM used by NIM on DGX                                         |
| `CURRENT_OLLAMA_VRAM_GB`     | `0`           | VRAM used by Ollama on DGX                                      |
| `CURRENT_OLLAMA_MODEL_AGX`   | `none`        | Ollama model currently loaded on AGX                            |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | `0`           | VRAM used by Ollama on AGX — the AGX band's whole VRAM figure   |

`CURRENT_NIM_MODEL_AGX` / `CURRENT_NIM_VRAM_GB_AGX` are obsolete: NIM has no
`linux/arm64` images and the AGX no longer runs k3s. The dashboard no longer
reads them.

## GitHub App credentials (no PATs)

Workflows never hold a long-lived GitHub token. Each job that writes GitHub state mints a
1-hour installation token with `actions/create-github-app-token` (revoked when the job ends).
Introduced after the Nov 2026 compromise, whose entry point was a leaked org-admin PAT.

| App                   | Permissions                                                                                         | Secrets (repo `miramar-platform-gcp`)                                 | Used by                                                       |
| --------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------- |
| `miramar-automation`  | Repo: Actions RW, Variables RW, Administration R, Contents R, Metadata R. Org: Variables RW          | `AUTOMATION_APP_CLIENT_ID`, `AUTOMATION_APP_KEY`                      | deploy/undeploy/install/gke/dashboard/traffic-report workflows |
| `miramar-provisioner` | Repo: Administration RW, Contents RW, Workflows RW, Pull requests RW, Secrets RW, Variables RW, Metadata R | `PROVISIONER_APP_CLIENT_ID`, `PROVISIONER_APP_KEY` — **environment `provision` only** (required reviewer: owner) | `create-project`, `delete-project`, `delete-blog-post`       |

The `provision` environment gate means a repo-admin-capable token is only ever minted after
the owner approves that specific run. Apps cannot use the packages API: delete GHCR
packages by hand.

`MIRAMAR_ORG_GHCR_PAT` (`read:packages`) remains only as the image-pull secret written into
k3s/GKE for private GHCR images; an App token would expire after an hour. Its org-secret
visibility must include `miramar-platform-gcp` (a public repo), or platform workflows and
Create Project read it as empty.

**Serving repos** are public, so org secrets scoped to private repos don't reach them.
Create Project copies `AUTOMATION_APP_CLIENT_ID`, `AUTOMATION_APP_KEY` and
`MIRAMAR_ORG_GHCR_PAT` into each new `serving-*` repo as repo secrets. Serving
deploy/undeploy mint `miramar-automation` tokens from them; image pushes use
`GITHUB_TOKEN` (`packages: write`). After rotating any of the three, re-set them in every
serving repo (`gh secret set NAME --repo miramar-labs-org/<repo>`).

## Host Environment Variables

Each self-hosted runner host keeps these in `~/.config/systemd/user/mlabs-runner.env`
(chmod 600). They are used by `launch-runner.sh` on the host and are not passed into the
runner container env:

| Variable               | What                                                       | Purpose                                                     |
| ---------------------- | ---------------------------------------------------------- | ----------------------------------------------------------- |
| `RUNNER_APP_CLIENT_ID` | Client ID of GitHub App `miramar-runner-registrar`         | Mint the single-use runner registration token               |
| `RUNNER_APP_KEY_FILE`  | Path to that App's private key (`.pem`, chmod 600)         | Same; App permission is Organization → Self-hosted runners RW only |
| `GITHUB_ORG_GHCR_PAT`  | PAT, `read:packages`                                       | Host `docker login` to pull `mlabs-runner` from GHCR        |

There is no org-admin PAT on any host. Admin scripts (`scripts/gha/runners.sh`,
`unregister-runner.sh`) use your interactive `gh` login (`gh auth refresh -s admin:org`).

The following optional host env var is used by the `/kfp-monitor` slash command (add to `~/.zshrc`):

| Variable            | Purpose                                                                                                                                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SLACK_WEBHOOK_URL` | Incoming webhook URL for Slack notifications. When set, `/kfp-monitor` POSTs a one-line summary to Slack on every terminal pipeline completion (PASS or FAIL). Degrades silently if unset. See [kfp-skills.md — Slack notifications](kfp-skills.md#slack-notifications). |

**Dashboard dispatch token (removed)** — `DASHBOARD_DISPATCH_TOKEN` used to be baked into the public dashboard HTML so its buttons could dispatch workflows. It was a classic `repo,workflow` PAT, and anyone could read it from the page; it was the entry point of the Nov 2026 account compromise. The dashboard is now token-free: its buttons link to the Actions *Run workflow* pages. Never template any credential into a GitHub Pages artifact.

Example:

```sh
# ~/.config/systemd/user/mlabs-runner.env
RUNNER_APP_CLIENT_ID=Iv23...
RUNNER_APP_KEY_FILE=/home/aaron/.config/mlabs-runner/registrar.pem
GITHUB_ORG_GHCR_PAT=ghp_...
```

`HF_TOKEN` and all other API keys are GitHub org secrets and do not need to be
set on individual machines — they are synced into the cluster automatically.

## Kubernetes Secret — `mlabs-api-keys`

The **Kubeflow Deploy** workflow creates (or updates) a Kubernetes Secret named
`mlabs-api-keys` in the `kubeflow` namespace immediately after the smoke-test
passes. This secret is the bridge from GHA org secrets into KFP component pods.

| Key in secret       | Source GHA secret   |
| ------------------- | ------------------- |
| `OPENAI_API_KEY`    | `OPENAI_API_KEY`    |
| `HF_TOKEN`          | `HF_TOKEN`          |
| `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` |
| `WANDB_API_KEY`     | `WANDB_API_KEY`     |
| `LANGCHAIN_API_KEY` | `LANGCHAIN_API_KEY` |
| `NGC_API_KEY`       | `NGC_API_KEY`       |
| `NVIDIA_API_KEY`    | `NVIDIA_API_KEY`    |

**To use in a KFP pipeline**, install `kfp-kubernetes` and add to the pipeline
function (after each task is constructed):

```python
from kfp import kubernetes as k8s_ext

SECRET = "mlabs-api-keys"
SECRET_KEYS = [
    "OPENAI_API_KEY", "HF_TOKEN", "ANTHROPIC_API_KEY",
    "WANDB_API_KEY", "LANGCHAIN_API_KEY", "NGC_API_KEY", "NVIDIA_API_KEY",
]
for task in [task1, task2, ...]:
    k8s_ext.use_secret_as_env(task, SECRET, {k: k for k in SECRET_KEYS})
```

The secret is idempotent — re-running **Kubeflow Deploy** updates it with the
current secret values. To verify on DGX:

```sh
kubectl get secret mlabs-api-keys -n kubeflow
```
