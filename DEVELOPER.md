# Developer Notes

## Branch workflow

```sh
# 1. Create a branch off main
git checkout -b my-feature

# 2. Make changes, commit
git add <files>
git commit -m "..."

# 3. Push and open a PR
git push -u origin my-feature
gh pr create --title "..." --body "..."

# 4. Merge and clean up
gh pr merge --squash --delete-branch

# 5. Sync local main
git checkout main
git pull
git branch -d my-feature
```

`gh pr merge --squash` merges and deletes the remote branch in one shot.

## Branch protection

`main` requires a pull request before merging (0 approvals — self-merge is allowed). Direct pushes and force pushes are blocked. Stale review dismissal is on.

`enforce_admins` is **off** — org admins and Claude Code (which runs as the org owner) can push directly to `main` and merge without a PR.

### Remove protection

```sh
gh api repos/miramar-labs-org/miramar-platform-gcp/branches/main/protection --method DELETE
```

### Re-apply protection

```sh
gh api repos/miramar-labs-org/miramar-platform-gcp/branches/main/protection \
  --method PUT \
  --header "Content-Type: application/json" \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

## Testing workflows before merging a PR

### Changes to an existing workflow

The workflow already exists on `main`, so GitHub can find it. Run it from your branch via CLI or UI:

```sh
gh workflow run deploy-ollama.yaml --ref my-feature --field model=llama3.3:70b-instruct-q4_K_M
gh run watch
```

Or via the GitHub UI: **Actions → [Workflow] → Run workflow → select branch → Run**.

### New workflow files

GitHub only discovers `workflow_dispatch` workflows that exist on the **default branch**. A workflow file that only exists on a feature branch cannot be triggered via the UI or `gh workflow run` — the API returns 404.

Workarounds:

**1. Add a `push` trigger on the feature branch** (recommended)

Add a `push` trigger scoped to the feature branch alongside `workflow_dispatch`. Every push to the branch fires the workflow with default inputs. Use `|| 'default'` fallbacks for all inputs since `push` events carry no `inputs`:

```yaml
on:
  push:
    branches:
      - my-feature
    paths:
      - '.github/workflows/my-workflow.yaml'  # scope to own file — without this, every push triggers every workflow on the branch
  workflow_dispatch:
    inputs:
      distro_name:
        default: dev

jobs:
  my-job:
    runs-on: ${{ inputs.runner || 'dgx' }}   # fallback required — push trigger carries no inputs
    steps:
      - run: echo "${{ inputs.distro_name || 'test' }}"  # fallback required
```

Push a commit to trigger it. **Remove the `push` trigger before merging** — a PR check (`pr-checks.yaml`) runs on every PR to `main` and fails if it finds push triggers on non-main branches.

**2. `gh` CLI after merge to main**

Merge the PR first, then test on main. Revert with another PR if broken.

**3. `act` — run locally**

[`act`](https://github.com/nektos/act) runs GitHub Actions workflows locally using Docker. No push needed.

## Setting secrets

```sh
gh secret set WSL2_HOST --body "192.168.1.x"
gh secret set WSL2_HOST_USER --body "aaron"
gh secret set WSL2_HOST_SSH_KEY < ~/.ssh/id_ed25519
gh secret set DGX_HOST_SSH_KEY < ~/.ssh/id_ed25519
```

Or via **Settings → Secrets and variables → Actions → New repository secret**.
