# Daily Org Repo Traffic Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scheduled GHA workflow in `miramar-platform-gcp` that pulls GitHub Traffic API data (views/unique visitors, clones/unique cloners) for every repo in `miramar-labs-org`, upserts it into the shared platform Postgres for long-term history, and posts a daily summary to `#miramar-platform-org` in Slack.

**Architecture:** One bash script (`scripts/org-traffic-report.sh`) does discovery/fetch/SQL-build/Slack-payload-build as small, independently testable functions with a `main()` entrypoint; one GHA workflow (`.github/workflows/org-traffic-report.yaml`) provides the SSH+kubectl-port-forward plumbing to reach the in-cluster Postgres and invokes the script on a daily cron plus `workflow_dispatch`.

**Tech Stack:** bash, `gh` CLI (GitHub API), `jq`, `psql`, `curl`, GitHub Actions (self-hosted `dgx` runner).

## Global Constraints

- Runner: `[self-hosted, dgx]` for the workflow job (matches every existing workflow in this repo).
- Org discovery/traffic calls authenticate with `secrets.MIRAMAR_ORG_ADMIN_PAT` (existing org-admin PAT, reused — no new PAT).
- Postgres connection via `secrets.ORG_TRAFFIC_DATABASE_URL` (new secret, added as a one-time manual prerequisite, not created by this plan's tasks).
- Slack delivery via `secrets.SLACK_WEBHOOK_URL` (already exists — do not create).
- Table: `repo_traffic_daily(date DATE, repo TEXT, visibility TEXT, views INT, unique_visitors INT, clones INT, unique_cloners INT, PRIMARY KEY (date, repo))`.
- Report date is **yesterday** (UTC), never "today" (today's traffic-API entry is a partial day).
- Workflow `permissions: contents: read` (no git writes — history lives in Postgres).
- Schedule: cron `0 13 * * *` + `workflow_dispatch`.
- Script style matches repo conventions: bash + `gh api` + `jq`, `set -euo pipefail`, passes `shellcheck`/`shfmt` (as enforced by the existing `Repo Code Quality Checker` workflow).

---

## File Structure

- Create: `miramar-platform-gcp/scripts/org-traffic-report.sh` — all report logic (discovery, fetch, SQL build, Slack payload build, `main()`). Sourceable (guarded `main` invocation) so its functions are unit-testable in isolation.
- Create: `miramar-platform-gcp/scripts/org-traffic-report.test.sh` — plain-bash test harness (no new test framework) that sources the script, stubs `gh`/`psql`/`curl` where needed, and asserts function outputs.
- Create: `miramar-platform-gcp/.github/workflows/org-traffic-report.yaml` — schedule/dispatch trigger, SSH + kubectl port-forward plumbing, invokes the script.

---

### Task 1: Repo discovery + per-repo traffic fetch

**Files:**
- Create: `scripts/org-traffic-report.sh` (initial skeleton + this task's functions)
- Test: `scripts/org-traffic-report.test.sh` (initial file)

**Interfaces:**
- Produces: `discover_repos()` — no args; reads `$ORG` (global, set to `"miramar-labs-org"`); prints one `<repo>\t<private:true|false>` line per non-archived repo to stdout.
- Produces: `fetch_repo_row(repo, private)` — args `$1=repo name`, `$2="true"|"false"`; reads `$REPORT_DATE` (global, `YYYY-MM-DD`); prints one SQL tuple string `('date','repo','visibility',views,unique_visitors,clones,unique_cloners)` to stdout, or prints nothing (and warns to stderr) if the repo's traffic data isn't accessible.

- [ ] **Step 1: Write the script skeleton with a sourcing guard**

Create `scripts/org-traffic-report.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ORG="miramar-labs-org"
REPORT_DATE="${REPORT_DATE:-$(date -u -d yesterday +%F)}"
DRY_RUN="${DRY_RUN:-false}"

log()  { echo "[org-traffic-report] $*" >&2; }
warn() { echo "[org-traffic-report] WARN: $*" >&2; }

discover_repos() {
  gh api "orgs/${ORG}/repos" --paginate --jq \
    '.[] | select(.archived == false) | "\(.name)\t\(.private)"'
}

fetch_repo_row() {
  local repo="$1" private="$2"
  local visibility views_json clones_json
  visibility=$([ "$private" = "true" ] && echo "private" || echo "public")

  if ! views_json=$(gh api "repos/${ORG}/${repo}/traffic/views" 2>/dev/null); then
    warn "skipping ${repo}: traffic/views not accessible"
    return 0
  fi
  if ! clones_json=$(gh api "repos/${ORG}/${repo}/traffic/clones" 2>/dev/null); then
    warn "skipping ${repo}: traffic/clones not accessible"
    return 0
  fi

  local views unique_visitors clones unique_cloners
  views=$(echo "$views_json" | jq --arg d "$REPORT_DATE" \
    '[.views[]? | select(.timestamp | startswith($d))][0].count // 0')
  unique_visitors=$(echo "$views_json" | jq --arg d "$REPORT_DATE" \
    '[.views[]? | select(.timestamp | startswith($d))][0].uniques // 0')
  clones=$(echo "$clones_json" | jq --arg d "$REPORT_DATE" \
    '[.clones[]? | select(.timestamp | startswith($d))][0].count // 0')
  unique_cloners=$(echo "$clones_json" | jq --arg d "$REPORT_DATE" \
    '[.clones[]? | select(.timestamp | startswith($d))][0].uniques // 0')

  printf "('%s','%s','%s',%s,%s,%s,%s)" \
    "$REPORT_DATE" "$repo" "$visibility" "$views" "$unique_visitors" "$clones" "$unique_cloners"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  : # main() added in Task 4
fi
```

- [ ] **Step 2: Write the failing test**

Create `scripts/org-traffic-report.test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

fail=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
}

# Stub `gh` before sourcing, so discover_repos/fetch_repo_row never hit the network.
gh() {
  case "$1 $2" in
    "api orgs/miramar-labs-org/repos")
      cat <<'JSON'
[{"name":"repo-a","private":false,"archived":false},{"name":"repo-b","private":true,"archived":false},{"name":"repo-old","private":false,"archived":true}]
JSON
      ;;
    "api repos/miramar-labs-org/repo-a/traffic/views")
      echo '{"views":[{"timestamp":"2026-08-16T00:00:00Z","count":42,"uniques":10}]}'
      ;;
    "api repos/miramar-labs-org/repo-a/traffic/clones")
      echo '{"clones":[{"timestamp":"2026-08-16T00:00:00Z","count":5,"uniques":3}]}'
      ;;
    *)
      return 1
      ;;
  esac
}
export -f gh

REPORT_DATE="2026-08-16"
DRY_RUN="true"
# shellcheck source=org-traffic-report.sh
source "$(dirname "$0")/org-traffic-report.sh"

repos_out="$(discover_repos)"
assert_eq "discover_repos excludes archived repos" \
  "$(printf 'repo-a\tfalse\nrepo-b\ttrue')" "$repos_out"

row_out="$(fetch_repo_row "repo-a" "false")"
assert_eq "fetch_repo_row builds correct SQL tuple" \
  "('2026-08-16','repo-a','public',42,10,5,3)" "$row_out"

exit "$fail"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `chmod +x scripts/org-traffic-report.test.sh && ./scripts/org-traffic-report.test.sh`
Expected: FAIL — `org-traffic-report.sh` doesn't exist yet (or, if Step 1 was already done, the test still can't pass until both files exist together — run this before Step 1's file is saved, or temporarily comment out Step 1's content to confirm red first).

- [ ] **Step 4: Confirm the implementation from Step 1 makes it pass**

Run: `./scripts/org-traffic-report.test.sh`
Expected: `PASS: discover_repos excludes archived repos`, `PASS: fetch_repo_row builds correct SQL tuple`, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/org-traffic-report.sh scripts/org-traffic-report.test.sh
git commit -m "feat(traffic-report): add repo discovery and per-repo traffic fetch"
```

---

### Task 2: SQL upsert builder

**Files:**
- Modify: `scripts/org-traffic-report.sh`
- Modify: `scripts/org-traffic-report.test.sh`

**Interfaces:**
- Consumes: nothing from Task 1 at call time (takes rows as a parameter — decoupled from `fetch_repo_row`'s loop, which is wired up in Task 4).
- Produces: `build_upsert_sql(rows)` — arg `$1` = newline-separated SQL tuples (as produced by `fetch_repo_row`); prints one SQL script to stdout containing `CREATE TABLE IF NOT EXISTS repo_traffic_daily (...)` followed by a single multi-row `INSERT ... ON CONFLICT (date, repo) DO UPDATE ...`. Prints nothing if `rows` is empty.

- [ ] **Step 1: Write the failing test**

Add to `scripts/org-traffic-report.test.sh`, before the final `exit "$fail"` line:

```bash
sql_out="$(build_upsert_sql "('2026-08-16','repo-a','public',42,10,5,3)
('2026-08-16','repo-b','private',7,2,0,0)")"
assert_eq "build_upsert_sql includes CREATE TABLE" \
  "1" "$(echo "$sql_out" | grep -c 'CREATE TABLE IF NOT EXISTS repo_traffic_daily')"
assert_eq "build_upsert_sql includes both value rows" \
  "1" "$(echo "$sql_out" | grep -c "repo-a" | grep -c "repo-b" || echo 0)"
assert_eq "build_upsert_sql includes ON CONFLICT upsert" \
  "1" "$(echo "$sql_out" | grep -c 'ON CONFLICT (date, repo) DO UPDATE')"

empty_sql="$(build_upsert_sql "")"
assert_eq "build_upsert_sql with no rows prints nothing" "" "$empty_sql"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/org-traffic-report.test.sh`
Expected: FAIL — `build_upsert_sql: command not found`.

- [ ] **Step 3: Implement `build_upsert_sql`**

Add to `scripts/org-traffic-report.sh`, after `fetch_repo_row`:

```bash
build_upsert_sql() {
  local rows="$1"
  [ -z "$rows" ] && return 0
  cat <<'SQL'
CREATE TABLE IF NOT EXISTS repo_traffic_daily (
  date             DATE NOT NULL,
  repo             TEXT NOT NULL,
  visibility       TEXT NOT NULL,
  views            INT NOT NULL,
  unique_visitors  INT NOT NULL,
  clones           INT NOT NULL,
  unique_cloners   INT NOT NULL,
  PRIMARY KEY (date, repo)
);
SQL
  echo "INSERT INTO repo_traffic_daily (date, repo, visibility, views, unique_visitors, clones, unique_cloners) VALUES"
  echo "$rows" | paste -sd, -
  echo ";"
  echo "-- upsert handled via ON CONFLICT below for re-runs of the same day"
  cat <<'SQL'
ON CONFLICT (date, repo) DO UPDATE SET
  visibility = EXCLUDED.visibility,
  views = EXCLUDED.views,
  unique_visitors = EXCLUDED.unique_visitors,
  clones = EXCLUDED.clones,
  unique_cloners = EXCLUDED.unique_cloners;
SQL
}
```

Note: the `INSERT ... VALUES (...)` and the trailing `ON CONFLICT` clause must be a single SQL statement (no semicolon between them) for Postgres to parse it as one upsert — fix the `echo ";"` line to NOT emit a semicolon after the VALUES rows; only the final `ON CONFLICT ... ;` line ends the statement. Corrected version: remove the standalone `echo ";"` line entirely.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/org-traffic-report.test.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/org-traffic-report.sh scripts/org-traffic-report.test.sh
git commit -m "feat(traffic-report): add Postgres upsert SQL builder"
```

---

### Task 3: Slack payload builder

**Files:**
- Modify: `scripts/org-traffic-report.sh`
- Modify: `scripts/org-traffic-report.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks at call time (takes pre-aggregated totals/top5 as parameters).
- Produces: `build_slack_payload(totals_csv, top5_csv)` — `$1` = `"views,unique_visitors,clones,unique_cloners"`, `$2` = newline-separated `"repo,unique_visitors"` rows (already ordered/limited to top 5 by the caller); prints a single-line JSON object `{"text": "..."}` to stdout suitable for `curl -d`.

- [ ] **Step 1: Write the failing test**

Add to `scripts/org-traffic-report.test.sh`:

```bash
payload_out="$(build_slack_payload "100,40,10,5" "$(printf 'repo-a,25\nrepo-b,15')")"
assert_eq "build_slack_payload is valid JSON" \
  "0" "$(echo "$payload_out" | jq empty; echo $?)"
assert_eq "build_slack_payload includes totals" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Views:.*100')"
assert_eq "build_slack_payload includes top repo" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'repo-a')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/org-traffic-report.test.sh`
Expected: FAIL — `build_slack_payload: command not found`.

- [ ] **Step 3: Implement `build_slack_payload`**

Add to `scripts/org-traffic-report.sh`, after `build_upsert_sql`:

```bash
build_slack_payload() {
  local totals_csv="$1" top5_csv="$2"
  local t_views t_uniq t_clones t_cloners
  IFS=',' read -r t_views t_uniq t_clones t_cloners <<< "$totals_csv"

  local top5_lines=""
  if [ -n "$top5_csv" ]; then
    top5_lines=$(echo "$top5_csv" | awk -F, '{printf "%d. *%s* \\u2014 %s unique visitors\\n", NR, $1, $2}')
  fi

  jq -n \
    --arg date "$REPORT_DATE" \
    --arg totals "Views: *${t_views:-0}* · Unique visitors: *${t_uniq:-0}* · Clones: *${t_clones:-0}* · Unique cloners: *${t_cloners:-0}*" \
    --arg top5 "$top5_lines" \
    '{text: (":bar_chart: *Org Repo Traffic — " + $date + "*\n" + $totals + "\n\n*Top 5 by unique visitors:*\n" + $top5)}'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/org-traffic-report.test.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/org-traffic-report.sh scripts/org-traffic-report.test.sh
git commit -m "feat(traffic-report): add Slack summary payload builder"
```

---

### Task 4: Wire `main()` with dry-run mode

**Files:**
- Modify: `scripts/org-traffic-report.sh`
- Modify: `scripts/org-traffic-report.test.sh`

**Interfaces:**
- Consumes: `discover_repos()`, `fetch_repo_row(repo, private)` (Task 1); `build_upsert_sql(rows)` (Task 2); `build_slack_payload(totals_csv, top5_csv)` (Task 3).
- Produces: `main()` — reads `$DRY_RUN` (`"true"|"false"`, default `"false"`), `$ORG_TRAFFIC_DATABASE_URL`, `$SLACK_WEBHOOK_URL`; when `DRY_RUN=true`, prints the SQL and Slack payload it *would* run/send instead of executing them, and never requires `ORG_TRAFFIC_DATABASE_URL`/`SLACK_WEBHOOK_URL` to be set.

- [ ] **Step 1: Write the failing test**

Add to `scripts/org-traffic-report.test.sh` (this exercises the full pipeline end-to-end with the stubbed `gh`, in dry-run mode, so no real DB/Slack calls happen):

```bash
dry_run_out="$(DRY_RUN=true REPORT_DATE=2026-08-16 GITHUB_STEP_SUMMARY=/dev/null main 2>&1)"
assert_eq "main dry-run prints the upsert SQL" \
  "1" "$(echo "$dry_run_out" | grep -c 'INSERT INTO repo_traffic_daily')"
assert_eq "main dry-run prints the Slack payload" \
  "1" "$(echo "$dry_run_out" | grep -c 'bar_chart')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/org-traffic-report.test.sh`
Expected: FAIL — `main: command not found`.

- [ ] **Step 3: Implement `main()`**

Replace the `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then : ; fi` placeholder at the bottom of `scripts/org-traffic-report.sh` with:

```bash
main() {
  local rows="" line repo private

  while IFS=$'\t' read -r repo private; do
    line=$(fetch_repo_row "$repo" "$private") || true
    [ -n "$line" ] && rows="${rows}${rows:+$'\n'}${line}"
  done < <(discover_repos)

  if [ -z "$rows" ]; then
    warn "no traffic rows collected for ${REPORT_DATE}; nothing to upsert"
    return 0
  fi

  local sql
  sql=$(build_upsert_sql "$rows")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN — would run this SQL:"
    echo "$sql"
  else
    echo "$sql" | psql "$ORG_TRAFFIC_DATABASE_URL" -v ON_ERROR_STOP=1
  fi

  local totals_query="SELECT COALESCE(SUM(views),0)||','||COALESCE(SUM(unique_visitors),0)||','||COALESCE(SUM(clones),0)||','||COALESCE(SUM(unique_cloners),0) FROM repo_traffic_daily WHERE date = '${REPORT_DATE}';"
  local top5_query="SELECT repo||','||unique_visitors FROM repo_traffic_daily WHERE date = '${REPORT_DATE}' ORDER BY unique_visitors DESC LIMIT 5;"

  local totals top5
  if [ "$DRY_RUN" = "true" ]; then
    totals="0,0,0,0"
    top5=""
  else
    totals=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$totals_query")
    top5=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$top5_query")
  fi

  local payload
  payload=$(build_slack_payload "$totals" "$top5")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN — would post this Slack payload:"
    echo "$payload"
  else
    curl -sf -X POST -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null
  fi

  {
    echo "## Org Traffic Report — ${REPORT_DATE}"
    echo "Rows upserted: $(echo "$rows" | wc -l)"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/org-traffic-report.test.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: Run shellcheck/shfmt locally to match repo quality gate**

Run: `shfmt -d scripts/org-traffic-report.sh scripts/org-traffic-report.test.sh && shellcheck scripts/org-traffic-report.sh scripts/org-traffic-report.test.sh`
Expected: no diff from `shfmt -d`, no findings from `shellcheck` (if either flags something, fix it before committing).

- [ ] **Step 6: Do a real dry-run against live GitHub (safe, read-only)**

Run: `cd miramar-platform-gcp && DRY_RUN=true GH_TOKEN="$(gh auth token)" ./scripts/org-traffic-report.sh`
Expected: prints discovered repos' warnings (if any are inaccessible) to stderr, then prints real upsert SQL and a real Slack payload to stdout — using your own `gh` auth, no `MIRAMAR_ORG_ADMIN_PAT` or platform secrets needed for this check. This is the first "real" end-to-end validation of Tasks 1–4 and requires no infra prerequisites.

- [ ] **Step 7: Commit**

```bash
git add scripts/org-traffic-report.sh scripts/org-traffic-report.test.sh
git commit -m "feat(traffic-report): wire main() with dry-run mode"
```

---

### Task 5: GHA workflow

**Files:**
- Create: `.github/workflows/org-traffic-report.yaml`

**Interfaces:**
- Consumes: `scripts/org-traffic-report.sh` (Task 4's `main()`, invoked as `./scripts/org-traffic-report.sh` with `DRY_RUN` unset/`false`).

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/org-traffic-report.yaml`:

```yaml
name: Org Traffic Report

on:
  schedule:
    - cron: "0 13 * * *"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  report:
    runs-on: [self-hosted, dgx]
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Set up SSH key
        run: |
          echo "${{ secrets.HOST_SSH_KEY }}" > /tmp/k_key
          chmod 600 /tmp/k_key
          ssh-keyscan -H "${{ vars.DGX_HOST_IP }}" >> ~/.ssh/known_hosts 2>/dev/null || true

      - name: Copy kubeconfig from host
        run: |
          mkdir -p ~/.kube
          scp -i /tmp/k_key -o StrictHostKeyChecking=no \
            "${{ vars.DGX_HOST_USER }}@${{ vars.DGX_HOST_IP }}:/home/${{ vars.DGX_HOST_USER }}/.kube/config" ~/.kube/config
          echo "KUBECONFIG=${HOME}/.kube/config" >> "$GITHUB_ENV"

      - name: Start Postgres port-forward
        run: |
          kubectl -n postgres-system port-forward svc/postgres 5432:5432 \
            > /tmp/port-forward.log 2>&1 &
          echo "PORT_FORWARD_PID=$!" >> "$GITHUB_ENV"
          sleep 3

      - name: Run traffic report
        env:
          GH_TOKEN: ${{ secrets.MIRAMAR_ORG_ADMIN_PAT }}
          ORG_TRAFFIC_DATABASE_URL: ${{ secrets.ORG_TRAFFIC_DATABASE_URL }}
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
        run: ./scripts/org-traffic-report.sh

      - name: Stop Postgres port-forward
        if: always()
        run: kill "${PORT_FORWARD_PID}" 2>/dev/null || true

      - name: Cleanup SSH key
        if: always()
        run: rm -f /tmp/k_key
```

- [ ] **Step 2: Validate the workflow syntax**

Run: `actionlint .github/workflows/org-traffic-report.yaml` (and `yamllint .github/workflows/org-traffic-report.yaml` if the repo-quality workflow runs it — check `repo-quality-manual.yaml` for the exact invocation it uses and match it).
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/org-traffic-report.yaml
git commit -m "feat(traffic-report): add scheduled GHA workflow"
```

- [ ] **Step 4: STOP — do not trigger this workflow yet**

Before a real `workflow_dispatch` run of this workflow can succeed, the one-time prerequisite from the design spec must be completed manually (this is a consequential action on shared platform infra and is **out of scope for this plan's tasks** — surface it back to the user rather than doing it autonomously):

1. Run **Postgres Deploy** (`deploy-postgres.yaml`) via `workflow_dispatch` with `consumer_db=org_traffic_report`, `consumer_user=org_traffic_report`.
2. Apply the `ALTER ROLE` workaround from `docs/dgx.md` § Postgres to get a known password (GitHub's log-masking redacts the printed `DATABASE_URL`).
3. Add the resulting connection string as a new repo secret `ORG_TRAFFIC_DATABASE_URL` in `miramar-platform-gcp`.

Only after those three steps exist should `workflow_dispatch` be run on `org-traffic-report.yaml` for a real end-to-end test.

---

## Self-Review

**Spec coverage:**
- Repo discovery (all non-archived org repos) → Task 1. ✓
- Traffic fetch, yesterday's date, 403-skip-and-continue → Task 1. ✓
- Postgres schema + upsert (idempotent via `ON CONFLICT`) → Task 2. ✓
- Slack summary (totals + top 5) → Task 3. ✓
- `main()` orchestration, DB-before-Slack ordering, dry-run → Task 4. ✓
- SSH + kubectl port-forward + cleanup (`if: always()`) → Task 5. ✓
- Schedule `0 13 * * *` + `workflow_dispatch` → Task 5. ✓
- `contents: read` permission (no git writes) → Task 5. ✓
- One-time Postgres consumer provisioning prerequisite → flagged explicitly as Task 5 Step 4, not silently executed. ✓
- `psql -v ON_ERROR_STOP=1` → Task 4 `main()`. ✓

**Placeholder scan:** no TBD/TODO; every step has literal code. The one caught issue (Task 2's stray `echo ";"` breaking the single-statement upsert) is called out and corrected inline rather than left as a bug.

**Type/name consistency:** `discover_repos`, `fetch_repo_row(repo, private)`, `build_upsert_sql(rows)`, `build_slack_payload(totals_csv, top5_csv)`, `main()` — names and arg order match everywhere they're referenced across Tasks 1–4 and in `org-traffic-report.yaml`'s invocation.

**Scope:** single subsystem (one script + one workflow), consistent with the approved design doc — no decomposition needed.
