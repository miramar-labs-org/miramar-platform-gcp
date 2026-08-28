# Design: Daily Org Repo Traffic Report

Date: 2026-08-17
Status: Approved (pending spec review)

## Goal

A daily automated report of GitHub repo traffic ("visitor info") across every
repo in the `miramar-labs-org` GitHub org — both the platform repos at org
root and the `projects/*` repos — posted to Slack, with real long-term
history kept in the platform's shared Postgres (GitHub's own Traffic API only
retains a rolling 14-day window).

## Scope

- **Data source:** GitHub's repo Traffic API (`/traffic/views`, `/traffic/clones`)
  — unique visitors + views, and unique cloners + clones, per repo per day.
  Not website analytics for `miramar-labs-org.github.io`; that's a separate,
  unrelated concern (deferred, not part of this design).
- **Repos covered:** every non-archived repo in the `miramar-labs-org` org,
  discovered dynamically via the GitHub API — no hardcoded list, so new repos
  are picked up automatically.
- **Out of scope:** top referrers/paths breakdown, backfilling data older
  than 14 days (impossible — GitHub doesn't retain it), web analytics for the
  Pages site.

## Architecture

### One-time setup (prerequisite, not part of the recurring workflow)

1. Run the existing **Postgres Deploy** GHA workflow
   (`miramar-platform-gcp/.github/workflows/deploy-postgres.yaml`) with
   `consumer_db=org_traffic_report`, `consumer_user=org_traffic_report` —
   same pattern already used for `multi_agent_ai_trader`.
2. Because GitHub's log-masking can redact the printed `DATABASE_URL`, use
   the `ALTER ROLE` workaround documented in `docs/dgx.md` § Postgres to pin
   a known password, then hand-assemble:
   `postgresql://org_traffic_report:<password>@postgres.postgres-system.svc.cluster.local:5432/org_traffic_report`
3. Store that as a new repo secret in `miramar-platform-gcp`:
   `ORG_TRAFFIC_DATABASE_URL`.

This setup is performed once, manually, before the workflow can run
successfully — it is not scripted as part of the daily job.

### Recurring workflow

New file: `miramar-platform-gcp/.github/workflows/org-traffic-report.yaml`

- **Runner:** `[self-hosted, dgx]`, matching every existing workflow in this
  repo.
- **Triggers:** `schedule` cron `0 13 * * *` (6am Pacific) + `workflow_dispatch`
  for manual/test runs.
- **Permissions:** `contents: read` (no git writes needed — history lives in
  Postgres, not in the repo).

Steps:

1. **Checkout** (`actions/checkout@v4`) — to get the script.
2. **Discover repos:** `gh api orgs/miramar-labs-org/repos --paginate
   --jq '.[] | select(.archived == false) | {name, private}'` using
   `GH_TOKEN=${{ secrets.MIRAMAR_ORG_ADMIN_PAT }}`.
3. **Fetch traffic per repo:** for each discovered repo, call
   `gh api repos/miramar-labs-org/{repo}/traffic/views` and
   `.../traffic/clones`. From each response's daily array, pick the entry
   dated **yesterday** (UTC) — today's entry is a partial/incomplete day in
   GitHub's rolling window, so it's excluded to keep numbers stable and
   final. A repo that 403s (token lacks push access) is logged as skipped
   and the run continues — not a hard failure.
4. **Connect to Postgres:** SSH to the DGX host (`vars.DGX_HOST_IP` /
   `vars.DGX_HOST_USER` / `secrets.HOST_SSH_KEY`, same as
   `deploy-postgres.yaml`), then `kubectl -n postgres-system port-forward
   svc/postgres 5432:5432 &` in the background on the runner. Cleanup
   (killing the port-forward, removing the temp SSH key) happens in an
   `if: always()` step.
5. **Ensure schema exists:**
   ```sql
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
   ```
6. **Upsert yesterday's rows** via `psql "$ORG_TRAFFIC_DATABASE_URL"`, one
   `INSERT ... ON CONFLICT (date, repo) DO UPDATE SET ...` per repo. The
   `ON CONFLICT` upsert makes re-running the workflow for the same day
   naturally idempotent — no separate dedup check needed.
7. **Query the day's summary:** a `SELECT` against `repo_traffic_daily`
   for `date = yesterday` computing org-wide totals (sum of views, unique
   visitors, clones, unique cloners) and the top 5 repos by
   `unique_visitors`.
8. **Post to Slack:** format the totals + top-5 table as a Slack message,
   `curl -X POST` to the existing `secrets.SLACK_WEBHOOK_URL`
   (`#miramar-platform-org`). This step runs *after* the DB upsert, so a
   Slack-side failure never loses collected data — but a failed Slack post
   should still fail the job loudly (via `set -euo pipefail` / checking the
   curl exit code) so it doesn't silently go unnoticed.

### Script

New file: `miramar-platform-gcp/scripts/org-traffic-report.sh` — bash +
`gh api` + `jq`, matching the existing style in `scripts/security/` and
`list-blog-posts.yaml`. Invoked by the workflow; not a standalone script
with its own trigger.

## Error handling

- Per-repo traffic fetch: `403`/error → log a warning line, skip that repo,
  continue the loop. Does not fail the job.
- `psql` invocations: `-v ON_ERROR_STOP=1` so a SQL error fails the step
  clearly instead of silently continuing past a broken upsert.
- Port-forward + temp SSH key cleanup: `if: always()`, so a mid-job failure
  doesn't leave the port-forward process or key file behind on the
  self-hosted runner.
- Slack post failure: job fails (non-zero exit), surfacing in GitHub Actions
  — but only *after* the DB upsert has already succeeded, so data isn't
  lost.

## Testing / verification

- Manual `workflow_dispatch` run first, before relying on the schedule.
- `GITHUB_STEP_SUMMARY` prints how many repos were discovered, how many
  traffic rows were upserted, and any skipped repos — so a run's outcome is
  visible without digging into raw logs.
- Verify in Slack that the message lands in `#miramar-platform-org` with
  sane-looking numbers.
- Verify via `kubectl -n postgres-system exec deploy/postgres -- psql -U
  org_traffic_report -d org_traffic_report -c 'SELECT * FROM
  repo_traffic_daily ORDER BY date DESC LIMIT 20;'` that rows are landing
  correctly.

## Open items for future iterations (not blocking this design)

- Popular *paths* breakdown per repo.
- Web analytics for `miramar-labs-org.github.io`.
- Weekly/monthly rollup views once enough history accumulates in
  `repo_traffic_daily`.
- Persist referrers to their own table for history (currently fetched live
  and shown, not stored).

## Amendments after the original design

Changes made after the initial implementation, in `scripts/org-traffic-report.sh`:

1. **Report date is "most recent complete day", not "yesterday".** GitHub's
   Traffic API has an unpredictable multi-day processing lag, so a fixed
   "yesterday" lookup silently produced all-zero rows. The script now resolves,
   per repo, the latest day actually present in the API's rolling window that
   is *not* today's still-accumulating UTC entry, and reports on whichever
   date the most repos share (`effective_date`).
2. **Public repos only.** `discover_repos` filters `.private == false` — private
   repo traffic is never fetched or stored. The summary/leaderboard queries
   also filter `visibility = 'public'` to exclude historical private rows.
3. **Leaderboard lists every public repo**, not a top-5/top-10 slice.
4. **Stars / forks / watchers.** New table `repo_stats_daily (date, repo,
   stars, forks, watchers)` snapshotted each run from `gh api
   repos/{org}/{repo}` (watchers = `subscribers_count`, not the legacy
   `watchers_count` alias). The summary shows org-wide totals with a
   day-over-day delta and a `:star:` callout naming repos that gained stars.
5. **Top referrers.** `gh api repos/{org}/{repo}/traffic/popular/referrers`
   per repo, summed by referrer across all public repos, top 5. This endpoint
   is a trailing-14-day aggregate, so the section is labelled as such — it is
   not a single-day figure like views/clones.
6. **Clones demoted.** Clone counts are dominated by CI (`actions/checkout`)
   and dev `git fetch`, so they moved to a single italic footnote line rather
   than the headline.
