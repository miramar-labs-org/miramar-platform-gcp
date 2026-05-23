# Miramar Platform Security Model

This document describes the intended trust boundaries, identity model, secrets handling, and hardening priorities for the Miramar Labs hybrid AI platform.

## Security goals

- Avoid long-lived cloud keys where GitHub Actions can use short-lived federated identity.
- Keep local GPU systems and local AI services reachable only through controlled local access paths.
- Separate GitHub-hosted and self-hosted runner responsibilities.
- Minimize plaintext secrets in repository content, logs, and workflow output.
- Treat runner hosts as privileged infrastructure because they can reach local systems and may hold operational credentials.

## Trust boundaries

| Boundary | Trusted side | Untrusted or less-trusted side | Notes |
|---|---|---|---|
| GitHub repository | Reviewed code on protected branches | Arbitrary pull requests and unreviewed workflow edits | Workflow changes can alter deployment behavior. |
| GitHub-hosted runners | Ephemeral Actions runtime | Local network and local GPU systems | Hosted runners should not receive direct local access. |
| Self-hosted runners | Operator-controlled machines | Public internet and arbitrary workflow payloads | Self-hosted runners are powerful and must be scoped carefully. |
| GCP project | IAM-managed cloud resources | External identities and unauthenticated clients | WIF should replace static service account keys. |
| DGX/local Kubernetes | Local AI workloads and storage | Cloud-side jobs and external clients | Local cluster access should be mediated through runner controls and tunnels. |
| Container registries | Signed or trusted images | Mutable tags and unverified downloads | Prefer immutable digests for critical deployments. |

## Identity model

### GitHub to GCP

GitHub Actions authenticates to Google Cloud through Workload Identity Federation. This avoids storing a GCP service account JSON key in GitHub secrets.

Recommended controls:

- Restrict the WIF provider to this organization and repository.
- Bind cloud roles to the minimum service account needed for each workflow class.
- Prefer separate service accounts for Terraform, deploy, artifact publishing, and read-only inspection.
- Limit destructive permissions to workflows that require manual dispatch and environment approval.

### Self-hosted runners

Self-hosted runners execute jobs on operator-managed machines. They should be treated as sensitive infrastructure because they may access:

- Local GPUs.
- Local Docker daemon.
- Local Kubernetes contexts.
- Local network services.
- SSH tunnels.
- Container registries.
- GCP credentials obtained through GitHub Actions.

Recommended controls:

- Use dedicated runner labels for host type and trust level.
- Avoid running untrusted pull-request jobs on self-hosted runners.
- Keep runner tokens short-lived and rotate them when hosts are rebuilt.
- Use one runner container per execution domain where practical.
- Keep host-level secrets out of the runner image.

## Secrets handling

Secrets should live in the narrowest appropriate store:

| Secret type | Preferred location |
|---|---|
| GitHub-to-GCP identity | Workload Identity Federation, not JSON keys. |
| GitHub package publishing | GitHub token or scoped PAT only where unavoidable. |
| NVIDIA/NGC credentials | GitHub Actions secret or host secret, never committed. |
| SSH private keys | Local host secret or GitHub secret only when workflow access is required. |
| Application runtime secrets | Kubernetes Secret, Secret Manager, or local sealed secret workflow. |
| Terraform variables | Non-secret values in repo; secrets in GitHub, GCP Secret Manager, or local env. |

Do not echo secrets in workflow logs. For scripts, prefer explicit input validation and redacted logging.

## Network model

### Local network

Local AI services should default to private/local reachability. Access to UIs such as MLflow, Kubernetes Dashboard, NeMo, NIM, or Ollama should use one of:

- SSH tunnel.
- Tailscale/WireGuard/VPN-style private network.
- Local-only port binding.
- Authenticated ingress where external exposure is required.

### GCP network

The current cloud setup is suitable for a lab platform. For stronger production posture, prioritize:

- Explicit VPC and subnet definitions.
- Private GKE nodes.
- Master authorized networks or equivalent control-plane access restriction.
- Workload Identity for Kubernetes workloads.
- Node service accounts with least privilege.
- Firewall rules scoped to required traffic only.
- Cloud NAT where private nodes need egress.

## Runner image supply-chain model

The `mlabs-runner` image is a high-privilege operational image. Because it installs many tools used by infrastructure workflows, it should be treated as part of the platform control plane.

Recommended controls:

- Pin tool versions.
- Verify downloaded binary checksums.
- Avoid remote shell installers where practical.
- Generate SBOMs during image build.
- Scan images with Trivy or Grype.
- Sign published images with cosign.
- Prefer digest-pinned images in production workflows.

## Kubernetes security posture

Recommended defaults for both local and cloud Kubernetes workloads:

- Use namespace-level resource quotas and limit ranges.
- Use service accounts per workload.
- Avoid default service account token use for workloads that do not need Kubernetes API access.
- Apply RBAC at the narrowest namespace scope possible.
- Use NetworkPolicy where the CNI supports it.
- Avoid privileged pods unless they are explicitly required for GPU/runtime operations.
- Store secrets in Kubernetes Secrets only as a baseline; use an external secret manager for production.

## Destructive operations

Workflows that create, destroy, resize, or restore infrastructure should include guardrails:

- `workflow_dispatch` only.
- Clear input names and defaults.
- `concurrency` locks per environment.
- `timeout-minutes`.
- GitHub environments with required reviewers.
- Terraform plan artifact before apply for non-lab environments.
- Explicit confirmation inputs for destructive operations.
- State backup before destructive operations.

## Recommended hardening backlog

1. Add repository-wide quality/security workflow:
   - `terraform fmt -check`
   - `terraform validate`
   - `tflint`
   - `actionlint`
   - `shellcheck`
   - `hadolint`
   - `trivy fs .`
2. Add image scanning and SBOM generation to runner image builds.
3. Pin and checksum all downloaded CLI tools.
4. Split cloud IAM into separate service accounts by workflow responsibility.
5. Add GKE private networking and least-privilege node service account.
6. Add branch protection and required status checks.
7. Add GitHub environments for apply/destroy workflows.
8. Add signed container images with cosign.
9. Add explicit policy for which workflows may run on self-hosted runners.
10. Document incident recovery for runner compromise, leaked token, or bad Terraform apply.

## Incident response notes

If a self-hosted runner or token is suspected to be compromised:

1. Disable or remove the runner in GitHub.
2. Stop the runner container on the host.
3. Rotate GitHub runner registration tokens.
4. Rotate any local credentials mounted into the runner.
5. Review recent workflow runs and logs.
6. Revoke suspicious GCP IAM bindings or service account access.
7. Rebuild the runner host or image if host compromise is possible.
8. Re-enable workflows only after trust is restored.
