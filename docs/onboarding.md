# Machine Onboarding

How to bring a new self-hosted runner machine into the Miramar platform alongside the existing machines (DGX Spark, AGX Orin).

Current machines and their labels:

| Machine | Runner label | IP | Arch |
|---|---|---|---|
| DGX Spark | `dgx` | 192.168.1.200 | arm64 |
| AGX Orin | `agx` | 192.168.1.202 | arm64 |

A new machine gets its own label (e.g. `dgx2`) and a corresponding variable prefix (`DGX2_*`).

---

## 1. Host setup (on the new machine)

### Static IP and hostname

Assign a static IP and set a recognisable hostname:

```sh
sudo hostnamectl set-hostname spark2-XXXX   # replace XXXX with last 4 of serial
```

Add a static lease in your router for the MAC address. Update `/etc/hosts` on all other machines to include the new hostname.

### inotify limits

The default `fs.inotify.max_user_instances=128` is too low for minikube. Apply on the new machine:

```sh
sudo tee /etc/sysctl.d/99-sysctl.conf <<'EOF'
fs.inotify.max_user_instances=1024
fs.inotify.max_user_watches=1048576
EOF
sudo sysctl --system
```

### SSH access

All machines share Spark's SSH identity via the `HOST_SSH_KEY` org secret and the shared SMB store on DGX. Run the shared SSH setup:

```sh
bash ~/shared/setup-shared-ssh.sh   # mounts //DGX/shared and symlinks ~/.ssh
```

Verify the runner container can SSH to the new machine:

```sh
ssh <NEW_HOST_USER>@<NEW_HOST_IP> echo ok
```

---

## 2. Start the runner

Pull and start the mlabs-runner container with the new machine's label:

```sh
RUNNER_LABEL=dgx2 \
RUNNER_NAME=dgx2-runner-01 \
GITHUB_ORG_ADMIN_PAT=<pat> \
GITHUB_ORG_GHCR_PAT=<pat> \
./scripts/gha/launch-runner.sh
```

The runner registers itself with GitHub Actions under `[self-hosted, dgx2]`. Verify it appears in **Settings → Actions → Runners** for the org.

---

## 3. Install systemd services

The seven platform services (minikube, dashboard, jupyterlab, port-forwards) are managed by systemd user units. The `dgx/systemd/` directory is canonical for arm64 machines:

```sh
# On the new machine
bash ~/git-miramar-labs-org/miramar-platform-gcp/dgx/systemd/install.sh
```

Enable linger so services start on boot without a login session:

```sh
loginctl enable-linger $USER
```

---

## 4. Org variables

Create these GitHub org-level variables (Settings → Actions → Variables, or via API):

| Variable | Example value | Notes |
|---|---|---|
| `DGX2_HOST_IP` | `192.168.1.203` | Static IP of new machine |
| `DGX2_HOST_USER` | `aaron` | SSH user |
| `DGX2_VRAM_USEABLE` | `100` | Usable VRAM in GB (total minus system reservation) |

Seed the active-state variables to `false`:

```sh
for svc in MINIKUBE NEMO MLFLOW KFP OLLAMA; do
  gh api --method PATCH \
    orgs/miramar-labs-org/actions/variables/DGX2_${svc}_ACTIVE \
    --field value=false \
    --field visibility=all 2>/dev/null || \
  gh api --method POST \
    orgs/miramar-labs-org/actions/variables \
    --field name=DGX2_${svc}_ACTIVE \
    --field value=false \
    --field visibility=all
done
```

If the new machine will run NIM or Ollama, also seed:

```sh
for var in CURRENT_NIM_MODEL_DGX2 CURRENT_OLLAMA_MODEL_DGX2; do
  gh api --method POST orgs/miramar-labs-org/actions/variables \
    --field name=$var --field value=none --field visibility=all
done
for var in CURRENT_NIM_VRAM_GB_DGX2 CURRENT_OLLAMA_VRAM_GB_DGX2; do
  gh api --method POST orgs/miramar-labs-org/actions/variables \
    --field name=$var --field value=0 --field visibility=all
done
```

---

## 5. Workflow updates

Every workflow with a `runner: choice [dgx, agx]` input needs the new label added. Affected workflows:

- `install-minikube.yaml`, `uninstall-minikube.yaml`, `toggle-minikube.yaml`
- `deploy-nemo.yaml`, `undeploy-nemo.yaml`
- `deploy-mlflow.yaml`, `undeploy-mlflow.yaml`
- `deploy-kubeflow.yaml`, `undeploy-kubeflow.yaml`
- `deploy-ollama.yaml`, `undeploy-ollama.yaml`, `update-ollama.yaml`
- `deploy-nim.yaml`, `undeploy-nim.yaml` (DGX-family only; skip if new machine won't run NIM)

In each workflow, two things need updating:

**a) Add the new label to the `inputs.runner` choices:**
```yaml
runner:
  type: choice
  options: [dgx, agx, dgx2]   # add dgx2
```

**b) Extend the `Resolve host vars` step** to handle the new prefix:
```bash
elif [[ "$RUNNER" == "dgx2" ]]; then
  HOST_IP="${DGX2_HOST_IP}"
  HOST_USER="${DGX2_HOST_USER}"
  VRAM_USEABLE="${DGX2_VRAM_USEABLE}"
  MACHINE="DGX2"
fi
```

Do this in a single PR so all workflows stay consistent.

> **Architecture note:** with three or more machines, consider refactoring `Resolve host vars` to be dynamic — derive the variable prefix from the runner label (`${RUNNER^^}_HOST_IP`) rather than a growing if/elif chain. A single generic step replaces the per-machine cases and makes future onboarding a config-only change.

---

## 6. Dashboard

`scripts/dashboard/generate-dashboard.sh` has hardcoded status sections for DGX and AGX. Add a DGX2 section following the same pattern (reads `DGX2_*_ACTIVE`, `CURRENT_OLLAMA_MODEL_DGX2`, etc.).

---

## 7. SSH tunnel port offsets

Each machine needs its own local port offset so multiple Bitvise tunnels can run simultaneously from the laptop:

| Service | DGX | AGX | DGX2 (suggested) |
|---|---|---|---|
| K8s dashboard | 8001 | 8002 | 8003 |
| JupyterLab | 8888 | 8887 | 8886 |
| MLflow | 5000 | 5001 | 5002 |
| KFP UI | 8080 | 8081 | 8079 |
| NeMo / NIM | 8082 | 8083 | 8084 |
| KFP API | 8890 | 8891 | 8892 |
| Ollama | 11434 | 11435 | 11436 |

Add a Bitvise profile (or SSH alias) for the new machine using these local ports.

---

## 8. Verification checklist

- [ ] Runner appears in GitHub org → Settings → Actions → Runners as `[self-hosted, dgx2]`
- [ ] `ssh <NEW_HOST_USER>@<NEW_HOST_IP> echo ok` works from runner container
- [ ] All seven systemd services are active (`systemctl --user status minikube jupyterlab ...`)
- [ ] Run **Minikube Install** workflow with `runner: dgx2` — passes
- [ ] Dashboard shows DGX2 status section with correct active/inactive badges after next deploy
- [ ] Org variable `DGX2_MINIKUBE_ACTIVE` flips to `true` after Minikube Install
