#!/usr/bin/env python3
"""gpu-bench — the standing GPU workload for Nsight smoke tests, both paths.

One workload definition, captured two ways:

  Compute (host)   `ncu` runs this file directly as the parent process and
                   replays kernels. This is the default `--tool compute` target
                   for scripts/nsight/export-report.sh, so a bare invocation with
                   no arguments must run a short, iteration-bounded workload and
                   exit 0.

  Systems (k3s)    `bench_workload` is wrapped as a KFP component (`--submit`)
                   and runs as a labelled step pod, where the Nsight Operator
                   injects nsys. That capture needs a workload that stays on the
                   GPU long enough for a collection window to land on it, so the
                   pipeline runs it time-bounded (`--seconds`).

`bench_workload` is defined once at module level and is self-contained — every
import is inside the body — so the same function object is both called directly
on the host and handed to `dsl.component()` for the in-cluster path. Do not add
module-level references to it; KFP ships the function's source to the container,
where nothing else in this file exists.

kfp is imported lazily. The host/ncu path runs under whichever interpreter has
torch+CUDA (`/usr/bin/python3` on the DGX), which need not have kfp installed.

Exit codes:
  0  workload ran
  2  usage / submit error
  3  host prerequisite missing (PyTorch not importable, or CUDA unavailable) —
     distinct from an `ncu` failure so the caller can tell the two apart.
"""
import argparse
import sys

# Matches the operator-injected image used by the KFP templates.
BASE_IMAGE = "nvcr.io/nvidia/pytorch:26.04-py3"
DEFAULT_SIZE = 4096
DEFAULT_ITERS = 30
DEFAULT_SECONDS = 300


def bench_workload(seconds: int = 0, iters: int = 30, size: int = 4096):
    """Run fp16 matmul + relu + add on the GPU.

    Time-bounded when `seconds` > 0, otherwise `iters` iterations. Kernels are
    issued from the first line — no warm-up sleep — so a capture opened the
    instant the pod goes Running still lands on real work.

    Self-contained by contract: KFP ships this function's *source text* to the
    container and re-executes the `def` there, so nothing outside the body may be
    referenced — not even module constants in the signature defaults (they would
    raise NameError at def time). Keep every default a literal and every import
    inside the body.
    """
    import sys
    import time

    try:
        import torch
    except ImportError:
        print(
            "gpu-bench: PyTorch not available on this interpreter — "
            "pass a workload with '-- <command>' instead",
            file=sys.stderr,
        )
        raise SystemExit(3)

    if not torch.cuda.is_available():
        print("gpu-bench: CUDA not available on this host", file=sys.stderr)
        raise SystemExit(3)

    # NVTX is optional: the KFP container pip-installs it (ranges then show up in
    # the Systems timeline), but neither host interpreter has it and `ncu` does
    # not need it. Fall back to a no-op so one body serves both.
    try:
        import nvtx

        annotate = nvtx.annotate
    except ImportError:
        import contextlib

        def annotate(*_args, **_kwargs):
            return contextlib.nullcontext()

    dev = torch.device("cuda")
    print(f"gpu-bench: {torch.cuda.get_device_name(0)}, {size}x{size} fp16", flush=True)

    a = torch.randn(size, size, device=dev, dtype=torch.float16)
    b = torch.randn(size, size, device=dev, dtype=torch.float16)

    deadline = time.time() + seconds if seconds > 0 else None
    i = 0
    while True:
        if deadline is not None:
            if time.time() >= deadline:
                break
        elif i >= iters:
            break
        with annotate(f"matmul_block_{i}", color="green"):
            c = a @ b
            c = torch.relu(c)
            c = c + a
            torch.cuda.synchronize()
        i += 1
        if deadline is not None and i % 50 == 0:
            print(f"gpu-bench: iter {i}", flush=True)

    mode = f"{seconds}s" if deadline is not None else f"{i} iters"
    print(f"gpu-bench: ok — {mode}, {i} iterations", flush=True)


def _build_pipeline(seconds: int, size: int):
    """Wrap bench_workload as a KFP pipeline. Imports kfp lazily."""
    from kfp import dsl, kubernetes

    stage = dsl.component(
        base_image=BASE_IMAGE,
        packages_to_install=["nvtx"],
    )(bench_workload)

    @dsl.pipeline(name="gpu-bench", description="Nsight Systems smoke-test target")
    def pipeline(seconds: int = seconds, iters: int = 0, size: int = size):
        task = stage(seconds=seconds, iters=iters, size=size)
        task.set_gpu_limit(1).set_memory_limit("32G")
        task.set_caching_options(False)
        # Per-pod label only. Labelling the kubeflow namespace would inject nsys
        # into KFP's own driver pods, which then fail runAsNonRoot.
        kubernetes.add_pod_label(
            task, label_key="nvidia-nsight-profile", label_value="enabled"
        )

    return pipeline


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="gpu-bench",
        description="GPU workload for Nsight smoke tests (host ncu + in-cluster nsys).",
    )
    p.add_argument("--seconds", type=int, default=0,
                   help="run time-bounded for N seconds (default: iteration-bounded)")
    p.add_argument("--iters", type=int, default=DEFAULT_ITERS,
                   help=f"iterations when not time-bounded (default {DEFAULT_ITERS})")
    p.add_argument("--size", type=int, default=DEFAULT_SIZE,
                   help=f"square matrix dimension (default {DEFAULT_SIZE})")
    p.add_argument("--compile", metavar="PATH",
                   help="compile the KFP pipeline to PATH and exit")
    p.add_argument("--submit", action="store_true",
                   help="submit the KFP pipeline and print the run id")
    p.add_argument("--kfp-host", default="http://localhost:8080",
                   help="KFP API endpoint for --submit (default %(default)s)")
    p.add_argument("--experiment", default="gpu-bench",
                   help="KFP experiment name for --submit (default %(default)s)")
    args = p.parse_args(argv)

    if args.compile or args.submit:
        pipeline_seconds = args.seconds if args.seconds > 0 else DEFAULT_SECONDS
        try:
            from kfp import compiler
            pipeline = _build_pipeline(pipeline_seconds, args.size)
        except ImportError as exc:
            print(f"gpu-bench: kfp not importable on {sys.executable}: {exc}",
                  file=sys.stderr)
            return 2

        if args.compile:
            compiler.Compiler().compile(pipeline, args.compile)
            print(f"gpu-bench: compiled -> {args.compile}")
            return 0

        import tempfile

        import kfp

        with tempfile.NamedTemporaryFile(suffix=".yaml") as tmp:
            compiler.Compiler().compile(pipeline, tmp.name)
            client = kfp.Client(host=args.kfp_host)
            try:
                exp = client.create_experiment(name=args.experiment)
            except Exception:
                exp = client.get_experiment(experiment_name=args.experiment)
            run = client.run_pipeline(
                experiment_id=exp.experiment_id,
                job_name="gpu-bench",
                pipeline_package_path=tmp.name,
            )
        print(f"gpu-bench: submitted, {pipeline_seconds}s on GPU")
        print(f"KFP_RUN_ID: {run.run_id}")
        return 0

    bench_workload(seconds=args.seconds, iters=args.iters, size=args.size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
