#!/usr/bin/env bash
# export-report.sh — get an Nsight profile into the durable, human-facing
# archive at ~/shared/nsight/.
#
# Deployed as ~/bin/nsight-export-report (a symlink to this file). All docs and
# skills reference the ~/bin path; this file is the reviewed source of truth.
#
# Two tools, two very different collection paths:
#
#   --tool systems  (default)  Nsight Systems, via the Nsight Operator:
#     MinIO (svc/nsight-operator-cloud-storage-minio) is the operator's internal
#     report storage; ~/shared/nsight is the durable archive that
#     /nsight-interpret, docs/dgx.md, and the template READMEs all assume.
#       full lifecycle (default) — create coordinator session -> collect -> wait
#                                  -> fetch report from MinIO -> verify -> release
#       export-only (--no-collect --report-id <uuid>) — pull an already-collected
#                                  report straight from MinIO (no session drive)
#     Needs the coordinator REST API (nsight-portfwd.service forwards it to
#     http://localhost:13001) and kubectl access to the nsight-operator namespace
#     (MinIO credentials secret + an ephemeral MinIO port-forward). Credentials
#     are read from the k8s secret at runtime and never persisted.
#
#   --tool compute             Nsight Compute, via host `ncu` — entirely
#     self-contained: no kube access, no coordinator, no MinIO. `ncu` must be the
#     parent process of the workload and replays each kernel many times, so it
#     cannot attach to a live KFP pod. This path runs a workload directly on the
#     host under `ncu` and writes profile.ncu-rep. --no-collect / --report-id are
#     systems-only and rejected here.

set -u

PROG=$(basename "$0")

# resolve through the ~/bin symlink so we can find sibling files (ncu-bench.py)
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir=$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)
  _src=$(readlink "$_src")
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
SCRIPT_DIR=$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
PROJECT="" RUN_ID="" STAGE=""
DURATION=60 DELAY=0
TOOL=systems
ADHOC=0
DEST_ROOT="${NSIGHT_DEST_ROOT:-$HOME/shared/nsight}"
KFP_RUN_ID="" MLFLOW_RUN=""
COORD_URL="http://localhost:13001"
MLFLOW_URL="${MLFLOW_TRACKING_URI:-http://localhost:5000}"
REPORT_ID="" NO_COLLECT=0
DO_SHA=1
NAMESPACE=kubeflow
POD=""

# Nothing is written to the durable archive until a report has passed
# verification. All intermediate work lands in $STAGING (a mktemp dir) and is
# copied to $DEST as the last step; a failed run leaves the archive untouched.
STAGING=""
PROMOTED=0
COMPUTE_DEST=""

# --tool compute only
NCU_SET=basic
NCU_LAUNCH_COUNT=20
KERNEL_NAME=""
TARGET_CMD=()

MINIO_NS=nsight-operator
MINIO_SVC=nsight-operator-cloud-storage-minio
MINIO_SECRET=nsight-operator-cloud-storage-minio-credentials
MINIO_BUCKET=nsight-reports

NSYS_VERSION_DEFAULT=2026.3.1

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
info()     { echo "$PROG: $*" >&2; }
warn()     { echo "$PROG: WARNING: $*" >&2; }
die()      { echo "$PROG: ERROR: $*" >&2; exit 1; }

# guard_durable_dest <dest> — refuse to mint a <project>/<run-id>/<stage>/ tree
# inside the durable archive (~/shared/nsight) unless this is a real project run.
# Only three kinds of entry belong directly under ~/shared/nsight: real
# <project>/<run-id>/<stage>/ trees, systems/, and compute/. A real project run is
# always driven from the project repo, so ./runs/<run-id>.md is present in $PWD
# (the skills cd into the repo; /nsight-export reads runs/<run>.md from there).
# Anything else is a throwaway / validation capture and must pass --adhoc (-> the
# systems/ | compute/ buckets) or --dest-root <scratch> (-> off the durable
# archive entirely). Note: an already-existing $DEST_ROOT/<project>/ dir is NOT a
# free pass — a dir left behind by a past mistake must not legitimise the next one.
guard_durable_dest() {
  local dest="$1"
  case "$dest/" in
    "$HOME/shared/nsight/"*) : ;;
    *) return 0 ;;                       # redirected off the durable archive — caller's call
  esac
  [ -f "./runs/$RUN_ID.md" ] && return 0
  die "refusing to write the durable archive path
     $dest
   '$PROJECT' has no ./runs/$RUN_ID.md in \$PWD ($PWD) — this looks like a
   throwaway / validation capture, not a real project run. Use one of:
     --adhoc                -> $DEST_ROOT/{systems,compute}/$PROJECT-<UTC-ts>/
     --dest-root <scratch>  -> keep it out of ~/shared/nsight entirely
   or run this from the project repo so ./runs/$RUN_ID.md is found."
}

usage() {
  cat >&2 <<EOF
Usage: $PROG --project <name> --run-id <run-NNN> --stage <stage> [options]

Required:
  --project <name>        project / repo name (caller supplies verbatim)
  --run-id <run-NNN>      human run id, e.g. run-059
  --stage <stage>         hyphenated KFP component name (baseline-eval,
                          fine-tune, post-finetune-eval, safety-eval,
                          baseline-safety-eval) or 'main' for single-stage

Tool:
  --tool systems|compute  default 'systems'
                          systems -> Nsight Systems via the Nsight Operator
                                     (KFP-integrated) -> profile.nsys-rep
                          compute -> Nsight Compute via host \`ncu\` (host-only,
                                     ad-hoc) -> profile.ncu-rep

Systems collection:
  --duration <sec>        collection window (default $DURATION)
  --delay <sec>           pre-collection delay (default $DELAY)

Systems export-only:
  --no-collect            skip the session drive; pull an existing report
  --report-id <uuid>      MinIO report uuid to pull (required with --no-collect)
  --coordinator-url <url> default $COORD_URL

Compute collection (--tool compute):
  --ncu-set <set>         ncu metric set: basic|detailed|full|roofline
                          (default $NCU_SET)
  --launch-count <N>      kernels to profile (default $NCU_LAUNCH_COUNT)
  --kernel-name <spec>    limit to matching kernels. <spec> is a plain function
                          name or 'regex:<expr>'. Passed to \`ncu --kernel-name\`.
  --kernel-regex <expr>   DEPRECATED alias for --kernel-name 'regex:<expr>'
  -- <command...>         workload to profile (must be last). If omitted, the
                          bundled scripts/nsight/ncu-bench.py GPU smoke bench is
                          run with the first torch+CUDA python found (override
                          with \$NCU_BENCH_PYTHON).

Destination:
  --adhoc                 land under
                          <root>/<systems|compute>/<project>-<UTC-ts>/
                          instead of <project>/<run-id>/<stage>/
  --dest-root <dir>       archive root (default ~/shared/nsight, or
                          \$NSIGHT_DEST_ROOT). Point validation / throwaway
                          captures elsewhere to keep the durable archive clean.

  A non-adhoc run writes the durable <project>/<run-id>/<stage>/ tree. Under
  ~/shared/nsight that is allowed only for a real project run — one driven from
  its repo, so ./runs/<run-id>.md is present in \$PWD. Otherwise the run is
  refused: pass --adhoc or --dest-root for a throwaway. An existing
  <root>/<project>/ dir left by a past mistake does not lift the refusal.

Metadata / linkage:
  --kfp-run-id <uuid>     KFP run UUID (metadata + MLflow tag)
  --mlflow-run <name>     MLflow run name, e.g. run-059-baseline — enables
                          MLflow tag linkage
  --namespace <ns>        stage pod namespace (default $NAMESPACE)
  --pod <name>            stage pod name (metadata only)

Misc:
  --no-sha256             skip the sha256 sidecar (default: write it)
  -h, --help              this help

On success prints:  EXPORTED: <path to profile.{nsys,ncu}-rep>
EOF
}

# mlflow_link <key=value>...   (no-op unless --mlflow-run given)
mlflow_link() {
  [ -n "$MLFLOW_RUN" ] || return 0
  local tags_json
  tags_json=$(python3 -c '
import json, sys
d = {}
for a in sys.argv[1:]:
    k, _, v = a.partition("=")
    if v:
        d[k] = v
print(json.dumps(d))
' "$@") || { warn "MLflow tag linkage: could not build tag set"; return 0; }

  NSE_MLFLOW_URL="$MLFLOW_URL" \
  NSE_MLFLOW_RUN="$MLFLOW_RUN" \
  NSE_EXPERIMENT="$PROJECT" \
  NSE_TAGS_JSON="$tags_json" \
  python3 - <<'PY' || warn "MLflow tag linkage failed (non-fatal)"
import json, os, sys, urllib.request

base = os.environ["NSE_MLFLOW_URL"].rstrip("/")
run_name = os.environ["NSE_MLFLOW_RUN"]
experiment = os.environ["NSE_EXPERIMENT"]
tags = json.loads(os.environ["NSE_TAGS_JSON"])

def api(path, payload):
    req = urllib.request.Request(
        f"{base}/api/2.0/mlflow/{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())

try:
    exp = api("experiments/get-by-name", {"experiment_name": experiment})
    exp_id = exp["experiment"]["experiment_id"]
except Exception as e:
    print(f"nsight-export-report: MLflow experiment '{experiment}' not found: {e}", file=sys.stderr)
    sys.exit(1)

res = api("runs/search", {
    "experiment_ids": [exp_id],
    "filter": f"attributes.run_name = '{run_name}'",
    "max_results": 1,
})
runs = res.get("runs", [])
if not runs:
    print(f"nsight-export-report: no MLflow run named '{run_name}' in '{experiment}'", file=sys.stderr)
    sys.exit(1)

run_id = runs[0]["info"]["run_id"]
for k, v in tags.items():
    if v:
        api("runs/set-tag", {"run_id": run_id, "key": k, "value": v})
print(f"nsight-export-report: tagged MLflow run {run_id} ({run_name})", file=sys.stderr)
PY
}

# ---------------------------------------------------------------------------
# --tool compute — host `ncu`, self-contained, exits when done
# ---------------------------------------------------------------------------
resolve_ncu() {
  local cand
  for cand in /opt/nvidia/nsight-compute/2026.2.1/ncu /usr/local/cuda/bin/ncu; do
    [ -x "$cand" ] && { echo "$cand"; return 0; }
  done
  cand=$(command -v ncu 2>/dev/null || true)
  [ -n "$cand" ] && { echo "$cand"; return 0; }
  return 1
}

# Interpreter for the bundled bench. $NCU_BENCH_PYTHON wins; otherwise the first
# of `python3` / `/usr/bin/python3` that can import torch with CUDA. Falls back to
# `python3` so the bench's own guard prints the clear "pass a workload" message.
pick_bench_python() {
  local p
  if [ -n "${NCU_BENCH_PYTHON:-}" ]; then echo "$NCU_BENCH_PYTHON"; return 0; fi
  for p in python3 /usr/bin/python3; do
    have_cmd "$p" || continue
    if "$p" -c 'import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)' >/dev/null 2>&1; then
      command -v "$p"; return 0
    fi
  done
  echo python3
}

run_ncu() {
  local dest="$1" ncu="$2"
  local -a args=(--set "$NCU_SET" --launch-count "$NCU_LAUNCH_COUNT" --target-processes all)
  [ -n "$KERNEL_NAME" ] && args+=(--kernel-name "$KERNEL_NAME")
  args+=(-f -o "$dest/profile")

  info "ncu: $ncu ${args[*]} -- ${TARGET_CMD[*]}"
  "$ncu" "${args[@]}" "${TARGET_CMD[@]}"
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    if [ -s "$dest/profile.ncu-rep" ]; then
      die "profiled command exited $rc (a report was still written) — the workload failed;
     ncu itself may be fine. Inspect the output above."
    fi
    die "ncu exited $rc and wrote no report — check GPU profiling permissions
     (perf_event_paranoid, RmProfilingAdminOnly) and that the workload runs
     standalone. Output above."
  fi

  [ -s "$dest/profile.ncu-rep" ] || die "ncu produced no report at $dest/profile.ncu-rep"

  if ! "$ncu" -i "$dest/profile.ncu-rep" --csv --page raw \
         >"$dest/summaries.csv" 2>"$dest/.verify.txt"; then
    cat "$dest/.verify.txt" >&2
    rm -f "$dest/.verify.txt"
    die "ncu could not read back $dest/profile.ncu-rep"
  fi
  rm -f "$dest/.verify.txt"
  if [ "$(wc -l <"$dest/summaries.csv")" -lt 2 ]; then
    die "no profiled kernels in $dest/profile.ncu-rep — raise --launch-count,
     widen --kernel-name, or confirm the workload launches CUDA kernels"
  fi
  "$ncu" -i "$dest/profile.ncu-rep" --page details >"$dest/ncu_details.txt" 2>/dev/null || true
}

compute_export() {
  [ "$NO_COLLECT" = 0 ] || die "--no-collect is systems-only (compute never touches operator storage)"
  [ -z "$REPORT_ID" ]   || die "--report-id is systems-only (compute never touches operator storage)"

  case "$NCU_SET" in
    basic|detailed|full|roofline) : ;;
    *) die "--ncu-set must be one of: basic detailed full roofline (got: $NCU_SET)" ;;
  esac
  case "$NCU_LAUNCH_COUNT" in
    ''|*[!0-9]*) die "--launch-count must be a positive integer (got: $NCU_LAUNCH_COUNT)" ;;
  esac

  have_cmd python3 || die "missing required command: python3"
  { [ "$DO_SHA" = 0 ] || have_cmd sha256sum; } || die "missing required command: sha256sum"

  local ncu
  ncu=$(resolve_ncu) || die "ncu (Nsight Compute) not found — looked in
     /opt/nvidia/nsight-compute/2026.2.1/ncu, /usr/local/cuda/bin/ncu, and \$PATH"

  local ts dest
  ts=$(date -u +%Y-%m-%dT%H%M%SZ)
  if [ "$ADHOC" = 1 ]; then
    dest="$DEST_ROOT/compute/${PROJECT}-${ts}"
  else
    dest="$DEST_ROOT/$PROJECT/$RUN_ID/$STAGE"
    guard_durable_dest "$dest"
  fi
  # stage in a temp dir; nothing reaches the archive until ncu + readback pass
  STAGING=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") || die "cannot create staging dir"
  COMPUTE_DEST="$dest"
  trap 'rc=$?; if [ "$PROMOTED" = 0 ]; then [ -n "$STAGING" ] && rm -rf "$STAGING"; [ "$rc" -ne 0 ] && info "run failed before verification — archive left untouched ($COMPUTE_DEST not created)"; fi; exit $rc' EXIT INT TERM
  info "destination: $dest (staging in $STAGING until verified)"

  if [ "${#TARGET_CMD[@]}" -eq 0 ]; then
    local bench="$SCRIPT_DIR/ncu-bench.py"
    [ -f "$bench" ] || die "bundled bench not found at $bench — pass a workload with '-- <command>'"
    local bench_py
    bench_py=$(pick_bench_python)
    info "bundled bench interpreter: $bench_py"
    TARGET_CMD=("$bench_py" "$bench")
  fi

  run_ncu "$STAGING" "$ncu"

  local ncu_version
  ncu_version=$("$ncu" --version 2>&1 | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

  local sha=""
  if [ "$DO_SHA" = 1 ]; then
    sha=$(sha256sum "$STAGING/profile.ncu-rep" | awk '{print $1}')
    echo "$sha  profile.ncu-rep" >"$STAGING/profile.ncu-rep.sha256"
  fi

  NSE_PROJECT="$PROJECT" \
  NSE_RUN_ID="$RUN_ID" \
  NSE_STAGE="$STAGE" \
  NSE_HOSTNAME="$(hostname -s)" \
  NSE_NAMESPACE="$NAMESPACE" \
  NSE_POD="$POD" \
  NSE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  NSE_NCU_VERSION="$ncu_version" \
  NSE_NCU_SET="$NCU_SET" \
  NSE_LAUNCH_COUNT="$NCU_LAUNCH_COUNT" \
  NSE_KERNEL_NAME="$KERNEL_NAME" \
  NSE_COMMAND="$(printf '%s\n' "${TARGET_CMD[@]}")" \
  NSE_SHA="$sha" \
  NSE_KFP_RUN_ID="$KFP_RUN_ID" \
  NSE_MLFLOW_RUN="$MLFLOW_RUN" \
  python3 - "$STAGING/profile.json" <<'PY'
import json, os, sys

def s(k):
    v = os.environ.get(k, "")
    return v if v != "" else None

cmd = [x for x in os.environ.get("NSE_COMMAND", "").split("\n") if x != ""]
lc = int(os.environ.get("NSE_LAUNCH_COUNT") or 0)
doc = {
    "project": s("NSE_PROJECT"),
    "run_id": s("NSE_RUN_ID"),
    "stage": s("NSE_STAGE"),
    "hostname": s("NSE_HOSTNAME"),
    "namespace": s("NSE_NAMESPACE"),
    "pod": s("NSE_POD"),
    "timestamp": s("NSE_TS"),
    "tool": "nsight-compute",
    "ncu_version": s("NSE_NCU_VERSION"),
    "ncu_set": s("NSE_NCU_SET"),
    "launch_count": lc,
    "kernel_name": s("NSE_KERNEL_NAME"),
    "command": cmd,
    "operator_session_id": None,
    "operator_report_id": None,
    "source_storage": None,
    "report": "profile.ncu-rep",
    "sha256": s("NSE_SHA"),
    "kfp_run_id": s("NSE_KFP_RUN_ID"),
    "mlflow_run": s("NSE_MLFLOW_RUN"),
    "mlflow_experiment": s("NSE_PROJECT") if s("NSE_MLFLOW_RUN") else None,
    "collection": {"launch_count": lc, "set": s("NSE_NCU_SET")},
}
with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
  info "wrote profile.json"

  # promote the staged, verified report into the durable archive
  mkdir -p "$dest" || die "cannot create destination: $dest"
  cp -p "$STAGING"/* "$dest"/ || die "could not promote staged report into $dest"
  PROMOTED=1
  rm -rf "$STAGING"
  info "archived to $dest"

  mlflow_link \
    "nsight_tool=compute" \
    "nsight_ncu_set=$NCU_SET" \
    "nsight_launch_count=$NCU_LAUNCH_COUNT" \
    "nsight_report_path=$dest/profile.ncu-rep" \
    "nsight_report_dir=$dest" \
    "nsight_report_sha256=$sha"

  info "verified: $(du -h "$dest/profile.ncu-rep" | awk '{print $1}')${sha:+  sha256=$sha}"
  echo "EXPORTED: $dest/profile.ncu-rep"
  exit 0
}

# ---------------------------------------------------------------------------
# parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --project)         PROJECT="${2:-}"; shift 2 ;;
    --run-id)          RUN_ID="${2:-}"; shift 2 ;;
    --stage)           STAGE="${2:-}"; shift 2 ;;
    --duration)        DURATION="${2:-}"; shift 2 ;;
    --delay)           DELAY="${2:-}"; shift 2 ;;
    --tool)            TOOL="${2:-}"; shift 2 ;;
    --adhoc)           ADHOC=1; shift ;;
    --dest-root)       DEST_ROOT="${2:-}"; shift 2 ;;
    --ncu-set)         NCU_SET="${2:-}"; shift 2 ;;
    --launch-count)    NCU_LAUNCH_COUNT="${2:-}"; shift 2 ;;
    --kernel-name)     KERNEL_NAME="${2:-}"; shift 2 ;;
    --kernel-regex)
      warn "--kernel-regex is deprecated; use --kernel-name <name|regex:re>"
      case "${2:-}" in
        regex:*) KERNEL_NAME="${2:-}" ;;
        *)       KERNEL_NAME="regex:${2:-}" ;;
      esac
      shift 2 ;;
    --kfp-run-id)      KFP_RUN_ID="${2:-}"; shift 2 ;;
    --mlflow-run)      MLFLOW_RUN="${2:-}"; shift 2 ;;
    --namespace)       NAMESPACE="${2:-}"; shift 2 ;;
    --pod)             POD="${2:-}"; shift 2 ;;
    --coordinator-url) COORD_URL="${2:-}"; shift 2 ;;
    --report-id)       REPORT_ID="${2:-}"; shift 2 ;;
    --no-collect)      NO_COLLECT=1; shift ;;
    --sha256)          DO_SHA=1; shift ;;
    --no-sha256)       DO_SHA=0; shift ;;
    --)                shift; TARGET_CMD=("$@"); break ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage; die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------
[ -n "$PROJECT" ] || { usage; die "--project is required"; }
[ -n "$RUN_ID" ]  || { usage; die "--run-id is required"; }
[ -n "$STAGE" ]   || { usage; die "--stage is required"; }
[ -n "$DEST_ROOT" ] || die "--dest-root / \$NSIGHT_DEST_ROOT cannot be empty"

case "$TOOL" in
  systems) EXT="nsys-rep" ;;
  compute) EXT="ncu-rep" ;;
  *) die "--tool must be 'systems' or 'compute' (got: $TOOL)" ;;
esac

case "$RUN_ID" in
  run-[0-9]*) : ;;
  *) warn "--run-id '$RUN_ID' does not look like 'run-NNN'" ;;
esac

# compute is a self-contained host path — dispatch before any operator dependency
if [ "$TOOL" = compute ]; then
  compute_export   # exits
fi

# ---------------------------------------------------------------------------
# systems path — Nsight Operator + coordinator + MinIO
# ---------------------------------------------------------------------------
if [ "$NO_COLLECT" = 1 ]; then
  [ -n "$REPORT_ID" ] || die "--no-collect requires --report-id <uuid>"
fi

for c in kubectl curl jq sha256sum python3 nsys; do
  have_cmd "$c" || die "missing required command: $c"
done

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# ---------------------------------------------------------------------------
# resolve destination
# ---------------------------------------------------------------------------
if [ "$ADHOC" = 1 ]; then
  DEST="$DEST_ROOT/systems/${PROJECT}-$(date -u +%Y-%m-%dT%H%M%SZ)"
else
  DEST="$DEST_ROOT/$PROJECT/$RUN_ID/$STAGE"
  guard_durable_dest "$DEST"
fi
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/${PROG}.XXXXXX") || die "cannot create staging dir"
REPORT_PATH="$STAGING/profile.$EXT"
info "destination: $DEST (staging in $STAGING until verified)"

# ---------------------------------------------------------------------------
# preflight — coordinator reachable
# ---------------------------------------------------------------------------
if ! curl -fsS -o /dev/null "$COORD_URL/api/v1/sessions/"; then
  die "coordinator REST API not reachable at $COORD_URL
     start it:  systemctl --user restart nsight-portfwd.service
     verify:    curl -fsS $COORD_URL/api/v1/sessions/
     (the :8889 SPA endpoint does NOT serve the REST API)"
fi

# ---------------------------------------------------------------------------
# MinIO — read credentials from the k8s secret (never persisted) + open an
# ephemeral port-forward for the duration of this run
# ---------------------------------------------------------------------------
MINIO_USER="" MINIO_PASS="" MINIO_PORT="" MINIO_PF_PID=""

minio_up() {
  MINIO_USER=$(kubectl -n "$MINIO_NS" get secret "$MINIO_SECRET" \
                 -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d) \
    || die "cannot read MinIO credentials secret ($MINIO_NS/$MINIO_SECRET)"
  MINIO_PASS=$(kubectl -n "$MINIO_NS" get secret "$MINIO_SECRET" \
                 -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d) \
    || die "cannot read MinIO credentials secret ($MINIO_NS/$MINIO_SECRET)"
  [ -n "$MINIO_USER" ] && [ -n "$MINIO_PASS" ] || die "MinIO credentials are empty"

  MINIO_PORT=19000
  while ss -ltn 2>/dev/null | grep -q ":$MINIO_PORT "; do
    MINIO_PORT=$((MINIO_PORT + 1))
  done

  kubectl -n "$MINIO_NS" port-forward "svc/$MINIO_SVC" "$MINIO_PORT:9000" \
    >"/tmp/${PROG}-minio-pf.$$.log" 2>&1 &
  MINIO_PF_PID=$!

  local i
  for i in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://localhost:$MINIO_PORT/minio/health/ready" 2>/dev/null; then
      return 0
    fi
    kill -0 "$MINIO_PF_PID" 2>/dev/null || die "MinIO port-forward died — see /tmp/${PROG}-minio-pf.$$.log"
    sleep 1
  done
  die "MinIO port-forward did not become ready on :$MINIO_PORT"
}

minio_down() {
  [ -n "$MINIO_PF_PID" ] && kill "$MINIO_PF_PID" 2>/dev/null
  MINIO_PF_PID=""
  rm -f "/tmp/${PROG}-minio-pf.$$.log"
}

# minio_get <object-key> <dest-file>
minio_get() {
  curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$MINIO_USER:$MINIO_PASS" \
    "http://localhost:$MINIO_PORT/$MINIO_BUCKET/$1" -o "$2"
}

# ---------------------------------------------------------------------------
# session lifecycle + cleanup trap
# ---------------------------------------------------------------------------
SID=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$SID" ]; then
    info "releasing coordinator session $SID"
    curl -fsS -o /dev/null -X DELETE "$COORD_URL/api/v1/sessions/$SID" 2>/dev/null \
      || warn "failed to DELETE session $SID — release it manually: curl -X DELETE $COORD_URL/api/v1/sessions/$SID"
    SID=""
  fi
  minio_down
  if [ "$PROMOTED" = 0 ] && [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
    rm -rf "$STAGING"
    [ "$rc" -ne 0 ] && info "run failed before verification — archive left untouched ($DEST not created)"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

REPORT_NAME=""

if [ "$NO_COLLECT" = 0 ]; then
  # --- create session ---
  title="$PROJECT/$RUN_ID/$STAGE"
  resp=$(curl -fsS -X POST "$COORD_URL/api/v1/sessions/" \
           -H 'content-type: application/json' \
           -d "{\"tag\":\"default\",\"title\":\"$title\"}") || {
    # surface a 409 clearly
    detail=$(curl -sS -X POST "$COORD_URL/api/v1/sessions/" \
               -H 'content-type: application/json' \
               -d "{\"tag\":\"default\",\"title\":\"$title\"}" 2>/dev/null)
    die "POST /sessions failed: ${detail:-<no body>}
     the 'default' service tag is held by an ACTIVE session.
     list:    curl -fsS $COORD_URL/api/v1/sessions/ | jq '.sessions[] | select(.status!=\"ENDED\")'
     release: curl -X DELETE $COORD_URL/api/v1/sessions/<sid>"
  }
  SID=$(echo "$resp" | jq -r '.session // .id // empty')
  [ -n "$SID" ] || die "could not parse session id from: $resp"
  info "created coordinator session $SID"

  # --- start collection ---
  curl -fsS -o /dev/null -X POST "$COORD_URL/api/v1/sessions/$SID/collect" \
    -H 'content-type: application/json' \
    -d "{\"duration\":$DURATION,\"delay\":$DELAY}" \
    || die "POST /sessions/$SID/collect failed"
  info "collecting: delay=${DELAY}s duration=${DURATION}s (trigger must land in the stage process's first few seconds — GPU hot from its first line)"

  # --- wait for the collection to finish ---
  sleep "$((DELAY + DURATION))"
  deadline=$(( $(date +%s) + 180 ))
  while :; do
    s=$(curl -fsS "$COORD_URL/api/v1/sessions/$SID" 2>/dev/null) || s=""
    active=$(echo "$s"  | jq -r '.activeCollectionID // "null"' 2>/dev/null || echo null)
    stopped=$(echo "$s" | jq -r '.collections[-1].stopped_at // "null"' 2>/dev/null || echo null)
    [ "$active" = "null" ] && [ "$stopped" != "null" ] && break
    [ "$(date +%s)" -gt "$deadline" ] && die "collection did not finish before deadline (session $SID, status: $(echo "$s" | jq -r .status 2>/dev/null))"
    sleep 5
  done
  info "collection complete"

  # --- resolve the produced report ---
  # The coordinator marks the collection stopped (and the session IDLE) a beat
  # before the finalized .nsys-rep is registered and listed under /files, so poll
  # the file list rather than reading it once.
  fdeadline=$(( $(date +%s) + 120 ))
  while :; do
    files=$(curl -fsS "$COORD_URL/api/v1/sessions/$SID/files" 2>/dev/null) || files=""
    REPORT_ID=$(echo "$files"   | jq -r '.files[0].uuid // empty' 2>/dev/null || echo "")
    REPORT_NAME=$(echo "$files" | jq -r '.files[0].filename // empty' 2>/dev/null || echo "")
    [ -n "$REPORT_ID" ] && break
    [ "$(date +%s)" -gt "$fdeadline" ] && die "no report file listed for session $SID after 120s — collection produced nothing (stage too short / not on GPU?)"
    sleep 5
  done
fi

# ---------------------------------------------------------------------------
# pull the report + manifest from MinIO
# ---------------------------------------------------------------------------
minio_up

if [ -z "$REPORT_NAME" ]; then
  minio_get "manifest/$REPORT_ID.json" "$STAGING/manifest.json" \
    || die "cannot fetch manifest for report $REPORT_ID from MinIO"
  REPORT_NAME=$(jq -r '.files[0].name // empty' "$STAGING/manifest.json")
  [ -n "$REPORT_NAME" ] || die "manifest for $REPORT_ID lists no report file"
else
  minio_get "manifest/$REPORT_ID.json" "$STAGING/manifest.json" \
    || warn "could not save manifest.json for $REPORT_ID"
fi

info "downloading $MINIO_BUCKET/$REPORT_ID/$REPORT_NAME"
minio_get "$REPORT_ID/$REPORT_NAME" "$REPORT_PATH" \
  || die "failed to download report $REPORT_ID/$REPORT_NAME from MinIO"

# ---------------------------------------------------------------------------
# verify — must NOT report success when the report is unusable
# ---------------------------------------------------------------------------
[ -s "$REPORT_PATH" ] || die "downloaded report is empty: $REPORT_PATH"

# Feed a freshly-exported .sqlite to every `nsys stats` call below. The report
# lands on the ~/shared network mount whose second-granularity mtimes trip
# nsys's "sqlite older than input" staleness check on repeat runs.
STATS_INPUT="$REPORT_PATH"
if ! nsys export --type sqlite --force-overwrite=true \
       --output "$STAGING/profile.sqlite" "$REPORT_PATH" >"$STAGING/.verify.txt" 2>&1; then
  cat "$STAGING/.verify.txt" >&2
  rm -f "$STAGING/.verify.txt"
  die "nsys export could not parse $REPORT_PATH"
fi
rm -f "$STAGING/.verify.txt"
STATS_INPUT="$STAGING/profile.sqlite"

if ! nsys stats --report cuda_gpu_kern_sum "$STATS_INPUT" >"$STAGING/.verify.txt" 2>&1; then
  cat "$STAGING/.verify.txt" >&2
  rm -f "$STAGING/.verify.txt"
  die "nsys stats could not read $STATS_INPUT"
fi
# data rows past the header/blank/title lines
if ! grep -Eq '^\s*[0-9]' "$STAGING/.verify.txt"; then
  rm -f "$STAGING/.verify.txt"
  die "no GPU kernel activity in the collected report — the collection was triggered too
     late in the stage process's life. On GB10 hw-trace the operator only retrieves GPU-side
     kernel timestamps when the collect is triggered within roughly the first few seconds of
     the profiled process starting; fire it ~60s in and the GPU-side records drop 'incomplete'
     even while the GPU is saturated (confirmed: hot GPU, window open, still zero kernels).
     Fire this with --delay 0 the instant the stage pod is Running, and make the workload
     issue kernels from its first line — no startup sleep. A longer --duration does not help."
fi
rm -f "$STAGING/.verify.txt"

SHA=""
if [ "$DO_SHA" = 1 ]; then
  SHA=$(sha256sum "$REPORT_PATH" | awk '{print $1}')
  echo "$SHA  profile.$EXT" > "$REPORT_PATH.sha256"
fi

# ---------------------------------------------------------------------------
# summaries — exactly the shape /nsight-interpret expects, so it skips regen
# ---------------------------------------------------------------------------
{ for _r in cuda_gpu_kern_sum cuda_api_sum cuda_gpu_mem_time_sum cuda_gpu_mem_size_sum nvtx_sum; do
    echo "=== ${_r} ==="
    nsys stats --report "${_r}" "$STATS_INPUT" 2>/dev/null || echo "(skipped)"
  done; } | tee "$STAGING/summaries.csv" > "$STAGING/nsys_stats.txt"

# ---------------------------------------------------------------------------
# profile.json sidecar
# ---------------------------------------------------------------------------
NSYS_VERSION="$NSYS_VERSION_DEFAULT"
if have_cmd nsys; then
  v=$(nsys --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$v" ] && NSYS_VERSION="$v"
fi

NSE_PROJECT="$PROJECT" \
NSE_RUN_ID="$RUN_ID" \
NSE_STAGE="$STAGE" \
NSE_HOSTNAME="$(hostname -s)" \
NSE_NAMESPACE="$NAMESPACE" \
NSE_POD="$POD" \
NSE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
NSE_TOOL="nsight-systems" \
NSE_NSYS_VERSION="$NSYS_VERSION" \
NSE_SID="$SID" \
NSE_REPORT_ID="$REPORT_ID" \
NSE_SOURCE="minio://$MINIO_BUCKET/$REPORT_ID/$REPORT_NAME" \
NSE_REPORT="profile.$EXT" \
NSE_SHA="$SHA" \
NSE_KFP_RUN_ID="$KFP_RUN_ID" \
NSE_MLFLOW_RUN="$MLFLOW_RUN" \
NSE_MLFLOW_EXPERIMENT="$PROJECT" \
NSE_DURATION="$DURATION" \
NSE_DELAY="$DELAY" \
python3 - "$STAGING/profile.json" <<'PY'
import json, os, sys

def s(k):
    v = os.environ.get(k, "")
    return v if v != "" else None

doc = {
    "project": s("NSE_PROJECT"),
    "run_id": s("NSE_RUN_ID"),
    "stage": s("NSE_STAGE"),
    "hostname": s("NSE_HOSTNAME"),
    "namespace": s("NSE_NAMESPACE"),
    "pod": s("NSE_POD"),
    "timestamp": s("NSE_TS"),
    "tool": s("NSE_TOOL"),
    "nsight_systems_version": s("NSE_NSYS_VERSION"),
    "operator_session_id": s("NSE_SID"),
    "operator_report_id": s("NSE_REPORT_ID"),
    "source_storage": s("NSE_SOURCE"),
    "report": s("NSE_REPORT"),
    "sha256": s("NSE_SHA"),
    "kfp_run_id": s("NSE_KFP_RUN_ID"),
    "mlflow_run": s("NSE_MLFLOW_RUN"),
    "mlflow_experiment": s("NSE_MLFLOW_EXPERIMENT") if s("NSE_MLFLOW_RUN") else None,
    "collection": {
        "duration_s": int(os.environ.get("NSE_DURATION") or 0),
        "delay_s": int(os.environ.get("NSE_DELAY") or 0),
    },
}
with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
info "wrote profile.json"

# ---------------------------------------------------------------------------
# promote the staged, verified report into the durable archive
# ---------------------------------------------------------------------------
mkdir -p "$DEST" || die "cannot create destination: $DEST"
cp -p "$STAGING"/* "$DEST"/ || die "could not promote staged report into $DEST"
PROMOTED=1
rm -rf "$STAGING"
REPORT_PATH="$DEST/profile.$EXT"
STATS_INPUT="$DEST/profile.sqlite"
info "archived to $DEST"

# ---------------------------------------------------------------------------
# MLflow linkage (additive — tags on the stage run; no template code needed)
# ---------------------------------------------------------------------------
mlflow_link \
  "nsight_tool=systems" \
  "nsight_report_path=$REPORT_PATH" \
  "nsight_report_dir=$DEST" \
  "nsight_report_sha256=$SHA" \
  "nsight_operator_session_id=$SID"

# ---------------------------------------------------------------------------
# done — session released by the cleanup trap
# ---------------------------------------------------------------------------
info "verified: $(du -h "$REPORT_PATH" | awk '{print $1}')${SHA:+  sha256=$SHA}"
echo "EXPORTED: $REPORT_PATH"
