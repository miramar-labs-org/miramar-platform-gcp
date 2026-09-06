#!/usr/bin/env python3
"""ncu-bench — a tiny GPU compute workload for Nsight Compute smoke tests.

The default `--tool compute` target for scripts/nsight/export-report.sh, and a
standalone "is host GPU compute profiling working?" check — parallel to the nsys
sanity-matmul in the nsys-gb10-profiling-guide memory.

Runs a handful of large fp16 matmul / elementwise iterations so `ncu` has real
kernels to profile, then exits 0. No arguments.

Exit codes:
  0  workload ran
  3  host prerequisite missing (PyTorch not importable, or CUDA unavailable) —
     distinct from an `ncu` failure so the caller can tell the two apart.
"""
import sys

try:
    import torch
except ImportError:
    print(
        "ncu-bench: host PyTorch not available — pass a workload with "
        "'-- <command>' instead",
        file=sys.stderr,
    )
    sys.exit(3)

if not torch.cuda.is_available():
    print("ncu-bench: CUDA not available on host", file=sys.stderr)
    sys.exit(3)


def main() -> None:
    dev = torch.device("cuda")
    torch.manual_seed(0)
    n = 4096
    a = torch.randn(n, n, device=dev, dtype=torch.float16)
    b = torch.randn(n, n, device=dev, dtype=torch.float16)

    for _ in range(30):
        c = a @ b
        c = torch.relu(c)
        a = c + b
    torch.cuda.synchronize()
    print(f"ncu-bench: ok — {torch.cuda.get_device_name(dev)}, {n}x{n} fp16 x30")


if __name__ == "__main__":
    main()
