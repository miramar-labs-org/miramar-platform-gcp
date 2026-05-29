#!/usr/bin/env bash
#
# repo-security-check.sh — security audit for a PUBLIC repo (tuned for a GCP infra repo).
# Run from the repo root:  ./scripts/security/repo-security-check.sh
# Read-only. Scans tracked files + history filenames; flags secrets, sensitive
# files, Terraform state, GCP keys, Actions risks, and internal-info leakage.
#
# For deep secret-history scanning, gitleaks/trufflehog are the gold standard:
#   gitleaks detect --source . --redact      (scans full git history for secrets)
# This script is a fast first pass that needs no extra tools.

[[ -d .git ]] || { echo "Run this from a git repo root."; exit 1; }

FAIL=0; WARN=0
red(){ printf '  \033[31m[RISK]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
yel(){ printf '  \033[33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
grn(){ printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
sub(){ printf '         %s\n' "$1"; }

TRACKED="$(git ls-files)"

echo "============================================================"
echo " Public-repo security check — $(basename "$(pwd)")"
echo "============================================================"

# ----------------------------------------------------------------
echo; echo "1) Sensitive files currently tracked"
PAT='(^|/)(\.env(\..*)?$|.*\.pem$|.*\.key$|.*\.p12$|.*\.pfx$|.*\.keystore$|.*\.jks$|id_rsa$|id_dsa$|id_ecdsa$|id_ed25519$|.*\.tfstate(\.backup)?$|kubeconfig$|.*\.kubeconfig$|\.npmrc$|\.pypirc$|\.htpasswd$|.*service[-_]?account.*\.json$|.*credentials.*\.json$|.*-sa\.json$)'
found=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # allow obvious templates/examples
  case "$f" in *.example|*.sample|*.template|*.dist) continue;; esac
  echo "$f" | grep -qiE "$PAT" && { red "tracked sensitive file: $f"; found=1; }
done <<< "$TRACKED"
[[ "$found" -eq 0 ]] && grn "no sensitive filenames tracked."

# ----------------------------------------------------------------
echo; echo "2) Terraform state / vars (plaintext secrets risk)"
tf=0
echo "$TRACKED" | grep -qiE '\.tfstate' && { red "Terraform STATE committed — it stores secrets in plaintext. Remove from repo + history."; tf=1; }
echo "$TRACKED" | grep -qiE '\.tfvars$' && { yel "*.tfvars tracked — fine if no secrets, but they often hold them. Verify."; tf=1; }
[[ "$tf" -eq 0 ]] && grn "no Terraform state/vars tracked."

# ----------------------------------------------------------------
echo; echo "3) Secret-like content in tracked files"
# Specific, low-false-positive signatures.
declare -A SIG=(
  ["GitHub token"]='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
  ["Google API key"]='AIza[0-9A-Za-z_-]{35}'
  ["GCP service-account key"]='"type":[[:space:]]*"service_account"'
  ["AWS access key"]='AKIA[0-9A-Z]{16}'
  ["Private key block"]='BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY'
  ["Slack token"]='xox[baprs]-[A-Za-z0-9-]{10,}'
  ["Stripe live key"]='sk_live_[A-Za-z0-9]{20,}'
  ["OpenAI/Anthropic key"]='sk-(ant-)?[A-Za-z0-9-]{20,}'
  ["JWT"]='eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  ["DB conn w/ password"]='(postgres|postgresql|mysql|mongodb(\+srv)?)://[^:/@[:space:]]+:[^@/[:space:]]+@'
)
sec=0
for name in "${!SIG[@]}"; do
  hitfiles="$(git grep -IlE "${SIG[$name]}" -- $(git ls-files | grep -viE '\.(example|sample|template|md|lock)$') 2>/dev/null)"
  if [[ -n "$hitfiles" ]]; then
    red "$name found in:"; echo "$hitfiles" | sed 's/^/           /'; sec=1
  fi
done
# Looser, high-false-positive assignments → WARN only.
loose="$(git grep -InE '(password|passwd|secret|api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*["'\''][^"'\'' ]{6,}' -- $(git ls-files | grep -viE '\.(example|sample|template|md|lock)$') 2>/dev/null | grep -viE 'example|dummy|changeme|<.*>|\$\{|placeholder' | head -15)"
[[ -n "$loose" ]] && { yel "hardcoded credential-looking assignments (review — may be false positives):"; echo "$loose" | sed 's/^/           /'; }
[[ "$sec" -eq 0 ]] && grn "no high-confidence secret signatures in tracked files."

# ----------------------------------------------------------------
echo; echo "4) Sensitive files that EVER existed in history"
sub "(secrets removed from HEAD still live in old commits unless history was purged)"
histpat='\.env$|\.pem$|\.key$|id_rsa|\.tfstate|service[-_]?account.*\.json|credentials.*\.json|-sa\.json|\.p12$|\.pfx$'
histhits="$(git log --all --pretty=format: --name-only --diff-filter=A 2>/dev/null | sort -u | grep -iE "$histpat" | head -20)"
if [[ -n "$histhits" ]]; then
  yel "these sensitive paths appear somewhere in git history:"
  echo "$histhits" | sed 's/^/           /'
  sub "If any held real secrets: rotate them, and purge with git-filter-repo (as you did for the PDFs)."
else
  grn "no sensitive filenames found in history."
fi

# ----------------------------------------------------------------
echo; echo "5) .gitignore coverage"
gi=".gitignore"
if [[ -f "$gi" ]]; then
  miss=()
  for p in '.env' '*.pem' '*.key' '*.tfstate' '*.tfvars' '*-sa.json' 'kubeconfig'; do
    grep -qiF "$p" "$gi" || miss+=("$p")
  done
  if [[ ${#miss[@]} -eq 0 ]]; then grn ".gitignore covers the common sensitive patterns."
  else yel ".gitignore is missing patterns: ${miss[*]}"; fi
else
  yel "no .gitignore at repo root."
fi

# ----------------------------------------------------------------
echo; echo "6) GitHub Actions exposure"
if [[ -d .github/workflows ]]; then
  grep -rqE 'pull_request_target' .github/workflows 2>/dev/null && { red "pull_request_target used — runs trusted, always, even on fork PRs. Audit for PR-code checkout."; } || grn "no pull_request_target."
  grep -rqEi 'runs-on:.*(self-hosted|dgx|agx|wsl2|spark|orin)' .github/workflows 2>/dev/null && { red "self-hosted runners referenced — risky on a PUBLIC repo (fork PRs could run on your hardware)."; } || grn "no self-hosted runners in workflows."
else
  grn "no .github/workflows directory."
fi

# ----------------------------------------------------------------
echo; echo "7) Internal-info / recon leakage"
recon="$(git grep -InE '(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+|spark-79b7|\borin\b|\bagx\b|wsl2)' -- $(git ls-files | grep -viE '\.(md|lock)$') 2>/dev/null | head -15)"
if [[ -n "$recon" ]]; then
  yel "internal hostnames/private IPs referenced (recon info on a public repo — usually low risk, but review):"
  echo "$recon" | sed 's/^/           /'
else
  grn "no obvious internal hostnames/private IPs in code."
fi

# ----------------------------------------------------------------
echo; echo "============================================================"
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  grn "Clean. No risks or warnings found."
elif [[ "$FAIL" -eq 0 ]]; then
  printf ' \033[33m%d warning(s), 0 risks.\033[0m Review the warnings above.\n' "$WARN"
else
  printf ' \033[31m%d RISK(s)\033[0m and %d warning(s). Address the [RISK] items first.\n' "$FAIL" "$WARN"
fi
echo
echo "Next-level: run a full-history secret scan with gitleaks:"
echo "  gitleaks detect --source . --redact"
echo "And in the browser: Settings -> Actions -> General (fork-PR approval, read-only token),"
echo "and rotate any secret this surfaced — assume public = already harvested."
