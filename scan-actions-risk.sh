#!/usr/bin/env bash
#
# scan-actions-risk.sh — flag risky GitHub Actions patterns in a public repo.
# Run from the repo root:  ./scan-actions-risk.sh
# Read-only; reports findings, changes nothing.

WF_DIR=".github/workflows"
[[ -d "$WF_DIR" ]] || { echo "No $WF_DIR here — run from the repo root."; exit 1; }

red(){   printf '\033[31m%s\033[0m\n' "$1"; }
yel(){   printf '\033[33m%s\033[0m\n' "$1"; }
grn(){   printf '\033[32m%s\033[0m\n' "$1"; }
hits=0

echo "Scanning $WF_DIR ..."
echo

# 1) pull_request_target — runs in trusted context, always runs, has secrets.
echo "[1] pull_request_target triggers"
if grep -rnH 'pull_request_target' "$WF_DIR" 2>/dev/null; then
  red "  ^ HIGH: these run in the TRUSTED base context with secrets + write token,"
  red "    and run even from fork PRs without approval. Safe ONLY if they never"
  red "    check out or execute the PR's code. Check finding [3] below."
  hits=1
else
  grn "  none — good."
fi
echo

# 2) self-hosted runners — fork PR code could execute on YOUR hardware.
echo "[2] self-hosted runners (your dgx/agx/wsl2 boxes)"
if grep -rnHE 'runs-on:.*(self-hosted|dgx|agx|wsl2|spark|orin)' "$WF_DIR" 2>/dev/null; then
  red "  ^ HIGH on a PUBLIC repo: jobs here can run on your own machines."
  red "    A fork PR reaching these could execute code in your lab network."
  red "    Mitigate: keep self-hosted runners off public-repo PR triggers,"
  red "    or restrict these workflows to non-PR events only."
  hits=1
else
  grn "  none — all jobs use GitHub-hosted runners."
fi
echo

# 3) The actual escalation: checking out PR head under a trusted trigger.
echo "[3] checkout of untrusted PR code (the exploit pattern)"
if grep -rnHE 'ref:[[:space:]]*\$\{\{[[:space:]]*github\.event\.pull_request\.head|github\.head_ref' "$WF_DIR" 2>/dev/null; then
  yel "  ^ REVIEW: a workflow checks out the PR's head ref. This is fine under"
  yel "    a normal 'pull_request' trigger, but DANGEROUS if combined with"
  yel "    'pull_request_target' (finding [1]) — that's the classic RCE chain."
  hits=1
else
  grn "  none — no PR-head checkout found."
fi
echo

# 4) Informational: which triggers and runners are in play.
# Parse only the `on:` block of each workflow (not stray keyword mentions in
# expressions/comments/descriptions), so triggers aren't over-reported.
echo "[4] summary of triggers and runners"
echo "  triggers used:"
for f in "$WF_DIR"/*.y*ml; do
  [[ -e "$f" ]] || continue
  # Inline form:  on: [push, pull_request]   or   on: push
  awk '
    /^on:[[:space:]]*\[/ { gsub(/^on:[[:space:]]*\[|\].*$/,""); gsub(/[[:space:]]/,""); n=split($0,a,","); for(i=1;i<=n;i++) print a[i]; next }
    /^on:[[:space:]]*[a-z]/ { sub(/^on:[[:space:]]*/,""); print $1; next }
    # Block form: collect indented keys under a bare "on:" until dedent.
    /^on:[[:space:]]*$/ { inblock=1; next }
    inblock && /^[[:space:]]+[a-z_]+:/ { line=$0; sub(/^[[:space:]]+/,"",line); sub(/:.*/,"",line); print line; next }
    inblock && /^[^[:space:]]/ { inblock=0 }
  ' "$f"
done | grep -E '^(push|pull_request|pull_request_target|workflow_dispatch|workflow_call|workflow_run|schedule)$' | sort -u | sed 's/^/    - /'
echo "  runners used:"
grep -rhE 'runs-on:' "$WF_DIR" 2>/dev/null | sed -E 's/.*runs-on:[[:space:]]*//' | tr -d '[]' | sort -u | sed 's/^/    - /'
echo

echo "----------------------------------------"
if [[ "$hits" -eq 0 ]]; then
  grn "No high-risk patterns found. For a public repo this is a clean bill."
else
  yel "Findings above. None are automatically exploitable, but review each —"
  yel "especially any [1]+[3] combination, or [2] self-hosted runners on PR triggers."
fi
echo
echo "Also check in the browser: Settings → Actions → General →"
echo "  • Fork pull request workflows: require approval for ALL outside collaborators"
echo "  • Workflow permissions: GITHUB_TOKEN = read-only by default"