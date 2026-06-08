#!/usr/bin/env python3
"""Purge large Nsight Systems artifacts from ~/shared/nsight/<project>/.

Default:
  - Delete .sqlite everywhere (always safe — regenerated from .nsys-rep by nsys stats)
  - Delete .nsys-rep for any component dir that already has summaries.csv

--sqlite-only: delete only .sqlite files, leave .nsys-rep intact.
--generate-missing: for dirs with .nsys-rep but no summaries.csv, run nsys stats
                    to generate summaries.csv first, then delete .nsys-rep.
--exclude run-NNN [run-MMM ...]: skip these runs entirely.
--dry-run: show what would be deleted without touching anything.
"""

import argparse
import subprocess
import sys
from pathlib import Path


def _fmt(n_bytes: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n_bytes < 1024:
            return f"{n_bytes:.1f} {unit}"
        n_bytes /= 1024
    return f"{n_bytes:.1f} TB"


def _generate_summaries(nsys_rep: Path, out: Path) -> None:
    reports = [
        "cuda_gpu_kern_sum",
        "cuda_api_sum",
        "cuda_gpu_mem_time_sum",
        "cuda_gpu_mem_size_sum",
        "nvtx_sum",
    ]
    lines = []
    for r in reports:
        lines.append(f"=== {r} ===\n")
        result = subprocess.run(
            ["nsys", "stats", "--report", r, "--format", "csv", str(nsys_rep)],
            capture_output=True,
            text=True,
        )
        lines.append(result.stdout if result.returncode == 0 else "(skipped)\n")
    out.write_text("".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sqlite-only", action="store_true",
                        help="Delete only .sqlite files")
    parser.add_argument("--generate-missing", action="store_true",
                        help="Generate summaries.csv before purging .nsys-rep for dirs that lack it")
    parser.add_argument("--exclude", metavar="RUN", nargs="+", default=[],
                        help="Run names to skip entirely (e.g. --exclude run-036 run-035)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be deleted without deleting")
    args = parser.parse_args()

    project = Path.cwd().name
    nsight_dir = Path.home() / "shared" / "nsight" / project

    if not nsight_dir.exists():
        print(f"No nsight data at {nsight_dir}")
        sys.exit(0)

    excluded = set(args.exclude)
    total_freed = 0
    file_count = 0

    # Each leaf directory corresponds to one component's profile output.
    # Structure: <nsight_dir>/<run-name>/<component>/
    for component_dir in sorted(nsight_dir.rglob("*")):
        if not component_dir.is_dir():
            continue

        # The run name is the first path segment below nsight_dir.
        run_name = component_dir.relative_to(nsight_dir).parts[0]
        if run_name in excluded:
            continue

        sqlite    = component_dir / "profile.sqlite"
        nsys_rep  = component_dir / "profile.nsys-rep"
        summaries = component_dir / "summaries.csv"

        to_delete = []

        if sqlite.exists():
            to_delete.append(sqlite)

        if not args.sqlite_only and nsys_rep.exists():
            if summaries.exists():
                to_delete.append(nsys_rep)
            elif args.generate_missing:
                rel = component_dir.relative_to(nsight_dir)
                print(f"  generating summaries.csv for {rel} ...")
                if not args.dry_run:
                    _generate_summaries(nsys_rep, summaries)
                to_delete.append(nsys_rep)

        for f in to_delete:
            size = f.stat().st_size
            total_freed += size
            file_count += 1
            rel = f.relative_to(nsight_dir)
            verb = "would delete" if args.dry_run else "deleting"
            print(f"  {verb}: {rel}  ({_fmt(size)})")
            if not args.dry_run:
                f.unlink()

    print()
    verb = "Would free" if args.dry_run else "Freed"
    print(f"{verb} {_fmt(total_freed)} across {file_count} file(s)")


if __name__ == "__main__":
    main()
