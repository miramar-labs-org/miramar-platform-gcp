#!/usr/bin/env bash
# Answer one question: does the KFP GPU base image actually execute GPU work on THIS host?
#
# Why this exists. `kfp-base-gpu` derives from `nvcr.io/nvidia/pytorch:26.04-py3` and is built
# only on the DGX (`build-kfp-base-images.yaml` → `runs-on: [self-hosted, dgx]`). NGC's arm64
# PyTorch containers target SBSA (Grace/GB10), not Tegra. Jetson serves its iGPU with the
# proprietary nvgpu driver and injects the L4T CUDA userspace into containers through the
# container runtime's CSV mode, so an SBSA image can be pulled and started on a Jetson and
# still fail to find a usable libcuda. "The image is arm64" does not mean "the image runs here".
#
# The failure is quiet in the way that matters: the pod starts, the stage runs, and the work
# lands on CPU (or dies inside a try/except) rather than announcing that the GPU was never used.
# So test the whole path, not the pull.
#
# Measured 2026-09-07:
#   DGX (GB10, RM)          PASS — torch 2.12/CUDA 13.2 ran a correct kernel in a kubeflow pod.
#   AGX (Orin, JetPack 6.2) not reached — GPU containers do not work on that host at all:
#                           `--runtime nvidia` injects no libcuda into a glibc container, k3s
#                           containerd has no nvidia runtime registered, and no nvidia.com/gpu
#                           is advertised to the cluster. Its GPU is host-only (Ollama).
#
# Two modes, because they exercise different runtimes:
#   docker — the nvidia docker runtime
#   k3s    — the containerd nvidia drop-in plus the device plugin's nvidia.com/gpu resource.
#            This is what KFP stages actually run under, so it is the authoritative answer.
#
# Exit: 0 all requested modes passed, 1 setup/usage error, 2 at least one mode failed.

set -uo pipefail

IMAGE="ghcr.io/miramar-labs-org/kfp-base-gpu:latest"
MODE="both"
NAMESPACE="kubeflow"
TIMEOUT=600
KEEP=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

usage() {
    cat <<'EOF'
Usage: check-kfp-gpu-image.sh [options]

  --image IMG       Image to test (default: ghcr.io/miramar-labs-org/kfp-base-gpu:latest)
  --mode MODE       docker | k3s | both   (default: both)
  --namespace NS    Namespace for k3s mode; must hold a GHCR pull secret
                    (default: kubeflow — where KFP stages actually run)
  --timeout N       Seconds to wait for the test pod (default: 600)
  --keep            Leave the test pod in place for inspection
  -h, --help        This message

The image is private, so each mode needs credentials:
  docker  docker login ghcr.io  (or GITHUB_ORG_GHCR_PAT in the environment)
  k3s     a dockerconfigjson secret in --namespace; auto-detected
EOF
}

die() { printf "${RED}error:${NC} %s\n" "$*" >&2; exit 1; }
hdr() { printf "\n${BLUE}== %s ==${NC}\n" "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)     IMAGE="${2:-}"; shift 2 ;;
        --mode)      MODE="${2:-}"; shift 2 ;;
        --namespace) NAMESPACE="${2:-}"; shift 2 ;;
        --timeout)   TIMEOUT="${2:-}"; shift 2 ;;
        --keep)      KEEP=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die "unknown argument: $1" ;;
    esac
done

case "$MODE" in
    docker|k3s|both) ;;
    *) die "--mode must be docker, k3s, or both" ;;
esac
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be an integer"

# ---------------------------------------------------------------------------
# The probe. Runs inside the container. Emits KEY=VALUE so the host can parse a
# verdict without scraping prose, and distinguishes *where* the path breaks:
#   10 no libcuda      — driver injection failed (the classic SBSA-on-Tegra outcome)
#   11 torch missing   — wrong image
#   12 no CUDA device  — libcuda present but device unusable
#   13 wrong answer    — kernels ran and returned garbage (worse than failing)
# ---------------------------------------------------------------------------
read -r -d '' PROBE_PY <<'PROBE'
import ctypes, os, platform, sys

def emit(k, v): print(f"{k}={v}", flush=True)

emit("python", platform.python_version())
emit("machine", platform.machine())
emit("is_tegra", os.path.exists("/etc/nv_tegra_release") or os.path.exists("/dev/nvgpu"))

try:
    ctypes.CDLL("libcuda.so.1")
    emit("libcuda", "ok")
except OSError as e:
    emit("libcuda", "MISSING")
    emit("libcuda_error", str(e).replace("\n", " ")[:200])
    sys.exit(10)

try:
    import torch
except ImportError as e:
    emit("torch", "MISSING")
    emit("torch_error", str(e)[:200])
    sys.exit(11)

emit("torch", torch.__version__)
emit("torch_cuda_build", torch.version.cuda)

if not torch.cuda.is_available():
    emit("cuda_available", "false")
    # Ask the driver directly — separates "no driver" from "driver present, no device".
    try:
        rc = torch.cuda.init()
        emit("cuda_init", str(rc))
    except Exception as e:
        emit("cuda_init_error", str(e).replace("\n", " ")[:300])
    sys.exit(12)

emit("cuda_available", "true")
emit("device_count", torch.cuda.device_count())
emit("device_name", torch.cuda.get_device_name(0))
emit("capability", "%d.%d" % torch.cuda.get_device_capability(0))

# Execute a real kernel and check the arithmetic. A GPU that runs but computes
# wrong is a worse outcome than one that refuses to run, so assert correctness.
#
# TF32 must be off for this comparison to mean anything. On Ampere and later,
# torch silently routes fp32 matmul through TF32 (~10-bit mantissa), and a
# 512-term accumulation then differs from a CPU fp32 reference by far more than
# any sane tolerance — which reads as "the GPU computed the wrong answer" when
# nothing is wrong at all. Disable it so a failure here is a real failure.
try:
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
except Exception:
    pass

try:
    g = torch.randn(512, 512, device="cuda")
    h = torch.randn(512, 512, device="cuda")
    out = torch.relu(g @ h)
    torch.cuda.synchronize()
    ref = torch.relu(g.cpu() @ h.cpu())
    close = torch.allclose(out.cpu(), ref, rtol=1e-3, atol=1e-3)
    emit("kernel", "ok")
    emit("kernel_correct", str(close).lower())
    emit("alloc_mb", round(torch.cuda.memory_allocated() / 1024**2, 1))
    if not close:
        sys.exit(13)
except Exception as e:
    emit("kernel", "FAILED")
    emit("kernel_error", str(e).replace("\n", " ")[:300])
    sys.exit(13)

emit("verdict", "PASS")
PROBE

PROBE_B64=$(printf '%s' "$PROBE_PY" | base64 -w0)
# base64 round-trip rather than quoting the payload through two runtimes
# Pick the interpreter by existence, not by exit status: a `python3 ... || python ...`
# fallback re-runs the whole probe whenever it exits non-zero, which is exactly the
# case we care about, and doubles the output at the worst moment.
IN_CONTAINER_CMD="echo ${PROBE_B64} | base64 -d > /tmp/probe.py && \
if command -v python3 >/dev/null 2>&1; then python3 /tmp/probe.py; else python /tmp/probe.py; fi"

# ---------------------------------------------------------------------------
# Host profile — the context that makes a result interpretable later.
# ---------------------------------------------------------------------------
hdr "Host"
MODEL="unknown"
[[ -r /proc/device-tree/model ]] && MODEL=$(tr -d '\0' < /proc/device-tree/model)
printf "  model:     %s\n" "$MODEL"
printf "  arch:      %s\n" "$(uname -m)"
[[ -f /etc/nv_tegra_release ]] && printf "  L4T:       %s\n" "$(head -1 /etc/nv_tegra_release)"

if [[ -e /dev/nvgpu ]] || lsmod 2>/dev/null | grep -q '^nvgpu'; then
    HOST_DRIVER="nvgpu"
    printf "  CUDA via:  ${YELLOW}nvgpu${NC} (Tegra iGPU — SBSA images are not expected to work)\n"
else
    HOST_DRIVER="rm"
    printf "  CUDA via:  nvidia.ko RM\n"
fi
command -v nvidia-smi >/dev/null 2>&1 && \
    printf "  GPU:       %s\n" "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
printf "  image:     %s\n" "$IMAGE"

# ---------------------------------------------------------------------------
# Result parsing shared by both modes.
# ---------------------------------------------------------------------------
report() {
    local mode="$1" rc="$2" out="$3"
    local dev; dev=$(grep -m1 '^device_name=' <<<"$out" | cut -d= -f2-)
    local tv;  tv=$(grep -m1 '^torch=' <<<"$out" | cut -d= -f2-)
    local ok;  ok=$(grep -m1 '^kernel_correct=' <<<"$out" | cut -d= -f2-)

    case "$rc" in
        0)
            printf "  ${GREEN}PASS${NC} — torch %s ran a kernel on %s (result correct: %s)\n" \
                "$tv" "${dev:-?}" "${ok:-?}"
            return 0 ;;
        10)
            printf "  ${RED}FAIL${NC} — libcuda.so.1 not loadable inside the container\n"
            printf "         %s\n" "$(grep -m1 '^libcuda_error=' <<<"$out" | cut -d= -f2-)"
            printf "         The runtime did not inject a usable CUDA driver library. On Tegra\n"
            printf "         this is the expected result for an SBSA-built image.\n"
            return 1 ;;
        11) printf "  ${RED}FAIL${NC} — no torch in the image (wrong image?)\n"; return 1 ;;
        12)
            printf "  ${RED}FAIL${NC} — libcuda loaded but no CUDA device is available\n"
            printf "         %s\n" "$(grep -m1 '^cuda_init_error=' <<<"$out" | cut -d= -f2-)"
            printf "         torch built against CUDA %s\n" \
                "$(grep -m1 '^torch_cuda_build=' <<<"$out" | cut -d= -f2-)"
            return 1 ;;
        13)
            printf "  ${RED}FAIL${NC} — kernel launch failed or returned a wrong result\n"
            printf "         %s\n" "$(grep -m1 '^kernel_error=' <<<"$out" | cut -d= -f2-)"
            return 1 ;;
        124) printf "  ${RED}FAIL${NC} — timed out after %ss\n" "$TIMEOUT"; return 1 ;;
        *)   printf "  ${RED}FAIL${NC} — %s exited %s (see output above)\n" "$mode" "$rc"; return 1 ;;
    esac
}

DOCKER_RESULT="skipped"
K3S_RESULT="skipped"

# ---------------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------------
run_docker() {
    hdr "docker"
    command -v docker >/dev/null 2>&1 || { printf "  ${YELLOW}SKIP${NC} — docker not installed\n"; return 0; }
    docker info >/dev/null 2>&1 || { printf "  ${YELLOW}SKIP${NC} — docker daemon unreachable\n"; return 0; }

    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        printf "  pulling %s ...\n" "$IMAGE"
        if [[ -n "${GITHUB_ORG_GHCR_PAT:-}" ]]; then
            printf '%s' "$GITHUB_ORG_GHCR_PAT" \
                | docker login ghcr.io -u "${GITHUB_ORG_GHCR_USER:-$USER}" --password-stdin >/dev/null 2>&1 \
                || printf "  ${YELLOW}note:${NC} ghcr login failed; trying anonymous pull\n"
        fi
        if ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
            printf "  ${RED}FAIL${NC} — cannot pull %s (private image: docker login ghcr.io)\n" "$IMAGE"
            DOCKER_RESULT="fail"; return 1
        fi
    fi

    # --gpus needs the nvidia container toolkit hook; Jetson installs commonly
    # only wire up `--runtime nvidia`. Try both before concluding anything.
    local out rc gpuflag="" f
    for f in "--gpus all" "--runtime nvidia"; do
        if timeout 60 docker run --rm $f "$IMAGE" true >/dev/null 2>&1; then gpuflag="$f"; break; fi
    done
    if [[ -z "$gpuflag" ]]; then
        printf "  ${RED}FAIL${NC} — neither '--gpus all' nor '--runtime nvidia' can start this image\n"
        DOCKER_RESULT="fail"; return 1
    fi
    printf "  GPU flag:  %s\n" "$gpuflag"

    out=$(timeout "$TIMEOUT" docker run --rm $gpuflag "$IMAGE" sh -c "$IN_CONTAINER_CMD" 2>&1)
    rc=$?
    grep -E '^[a-z_]+=' <<<"$out" | sed 's/^/    /'
    grep -qE '^[a-z_]+=' <<<"$out" || printf "%s\n" "$out" | tail -15 | sed 's/^/    /'
    if report docker "$rc" "$out"; then DOCKER_RESULT="pass"; else DOCKER_RESULT="fail"; return 1; fi
}

# ---------------------------------------------------------------------------
# k3s — the authoritative path: same namespace, runtime and GPU resource that
# KFP stages get.
# ---------------------------------------------------------------------------
run_k3s() {
    hdr "k3s (namespace: $NAMESPACE)"
    command -v kubectl >/dev/null 2>&1 || { printf "  ${YELLOW}SKIP${NC} — kubectl not installed\n"; return 0; }
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || {
        printf "  ${YELLOW}SKIP${NC} — namespace %s not found (k3s not deployed?)\n" "$NAMESPACE"; return 0; }

    local gpucap
    gpucap=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '+' | sed 's/+$//')
    if [[ -z "$gpucap" || "$gpucap" == "0" ]]; then
        printf "  ${RED}FAIL${NC} — no allocatable nvidia.com/gpu on any node (device plugin not running)\n"
        K3S_RESULT="fail"; return 1
    fi
    printf "  nvidia.com/gpu allocatable: %s\n" "$gpucap"

    local secret
    secret=$(kubectl get secrets -n "$NAMESPACE" --field-selector type=kubernetes.io/dockerconfigjson \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$secret" ]]; then
        printf "  pull secret: %s\n" "$secret"
    else
        printf "  ${YELLOW}note:${NC} no dockerconfigjson secret in %s — a private image will fail to pull\n" "$NAMESPACE"
    fi

    local pod="kfp-gpu-imagecheck-$$"
    cleanup_pod() { [[ "$KEEP" == true ]] || kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1; }
    trap cleanup_pod RETURN

    {
        printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n' "$pod" "$NAMESPACE"
        printf '  restartPolicy: Never\n'
        [[ -n "$secret" ]] && printf '  imagePullSecrets:\n  - name: %s\n' "$secret"
        printf '  containers:\n  - name: probe\n    image: %s\n' "$IMAGE"
        printf '    command: ["sh","-c"]\n    args:\n    - %s\n' "$(printf '%s' "$IN_CONTAINER_CMD" | sed 's/"/\\"/g; s/^/"/; s/$/"/')"
        printf '    resources:\n      limits:\n        nvidia.com/gpu: 1\n'
    } | kubectl apply -f - >/dev/null 2>&1 || { printf "  ${RED}FAIL${NC} — could not create test pod\n"; K3S_RESULT="fail"; return 1; }

    printf "  waiting for %s (timeout %ss) ...\n" "$pod" "$TIMEOUT"
    local waited=0 phase=""
    while (( waited < TIMEOUT )); do
        phase=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        # Surface an image-pull problem immediately instead of burning the timeout.
        local reason
        reason=$(kubectl get pod "$pod" -n "$NAMESPACE" \
                 -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
        if [[ "$reason" == "ErrImagePull" || "$reason" == "ImagePullBackOff" ]]; then
            printf "  ${RED}FAIL${NC} — image pull failed (%s)\n" "$reason"
            kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=$pod" \
                -o custom-columns=MSG:.message --no-headers 2>/dev/null | tail -3 | sed 's/^/         /'
            K3S_RESULT="fail"; return 1
        fi
        sleep 5; waited=$((waited + 5))
    done

    local out rc
    out=$(kubectl logs "$pod" -n "$NAMESPACE" 2>&1)
    if [[ "$phase" == "Succeeded" ]]; then
        rc=0
    elif [[ "$phase" == "Failed" ]]; then
        rc=$(kubectl get pod "$pod" -n "$NAMESPACE" \
             -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
        rc="${rc:-1}"
    else
        rc=124
    fi

    grep -E '^[a-z_]+=' <<<"$out" | sed 's/^/    /'
    grep -qE '^[a-z_]+=' <<<"$out" || printf "%s\n" "$out" | tail -15 | sed 's/^/    /'
    if report k3s "$rc" "$out"; then K3S_RESULT="pass"; else K3S_RESULT="fail"; return 1; fi
}

[[ "$MODE" == "docker" || "$MODE" == "both" ]] && run_docker
[[ "$MODE" == "k3s"    || "$MODE" == "both" ]] && run_k3s

# ---------------------------------------------------------------------------
hdr "Verdict"
printf "  docker: %s\n  k3s:    %s\n" "$DOCKER_RESULT" "$K3S_RESULT"

if [[ "$DOCKER_RESULT" == "fail" || "$K3S_RESULT" == "fail" ]]; then
    printf "\n  ${RED}%s cannot run GPU work on this host.${NC}\n" "$IMAGE"
    if [[ "$HOST_DRIVER" == "nvgpu" ]]; then
        printf "  Consistent with an SBSA-built NGC image on a Tegra host. This is a\n"
        printf "  pre-existing gap, independent of any Nsight or JetPack question: GPU KFP\n"
        printf "  stages cannot have been running here. Fixing it means an L4T-based GPU\n"
        printf "  base image for arm64-tegra, or moving the host off nvgpu.\n"
    fi
    exit 2
fi
if [[ "$DOCKER_RESULT" == "skipped" && "$K3S_RESULT" == "skipped" ]]; then
    printf "\n  ${YELLOW}Nothing ran.${NC}\n"; exit 1
fi
printf "\n  ${GREEN}%s executes GPU work on this host.${NC}\n" "$IMAGE"
exit 0
