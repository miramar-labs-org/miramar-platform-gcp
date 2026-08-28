#!/usr/bin/env python3
"""
Freeze a LangSmith trace slice into the bakeoff's eval dataset.

For each `langsmith.export` spec in config.yaml this:
  1. lists matching runs from the LangSmith project,
  2. extracts `{inputs, reference}` per run via the spec's dotted paths,
  3. writes ./dataset/<task>.jsonl  (one case per line),
  4. writes ./dataset/manifest.json (counts, date range, source run ids),
  5. uploads ./dataset/* to s3://<dataset.bucket>/datasets/<version>/ (MinIO).

The KFP `load_dataset` component reads that same S3 prefix at run time.

Usage:
  LANGCHAIN_API_KEY=...  python3 scripts/export_dataset.py --version v20260828
  python3 scripts/export_dataset.py --version v20260828 --local-only   # skip upload
  python3 scripts/export_dataset.py --version v20260828 --dry-run      # list only

Case row schema (each line of <task>.jsonl):
  {"case_id": str, "provenance": "real"|"synthetic", "inputs": <any>, "reference": <any>}
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import sys

_ROOT = pathlib.Path(__file__).resolve().parent.parent
_OUT = _ROOT / "dataset"


def _dig(obj, path: str):
    """Follow a dotted path (`a.b.0.c`) into nested dicts/lists; None if absent."""
    cur = obj
    if not path:
        return cur
    for part in path.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        elif isinstance(cur, (list, tuple)):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return cur


def _load_cfg() -> dict:
    import yaml
    return yaml.safe_load((_ROOT / "config.yaml").read_text())


def _export_task(client, project: str, spec: dict, dry_run: bool):
    task = spec["task"]
    runs = list(client.list_runs(
        project_name=project,
        filter=spec.get("run_filter") or None,
        limit=int(spec.get("limit", 50)),
    ))
    print(f"[{task}] {len(runs)} run(s) from LangSmith project {project!r}")

    cases, run_ids, times = [], [], []
    for i, run in enumerate(runs):
        row = run.dict() if hasattr(run, "dict") else dict(run)
        inputs = _dig(row, spec.get("input_path", "inputs"))
        reference = _dig(row, spec.get("output_path", "outputs"))
        if inputs is None:
            print(f"  skip {row.get('id')}: no inputs at {spec.get('input_path')!r}")
            continue
        cases.append({
            "case_id": f"{task}-{i:03d}",
            "provenance": "real",
            "inputs": inputs,
            "reference": reference,
        })
        run_ids.append(str(row.get("id")))
        if row.get("start_time"):
            times.append(str(row["start_time"]))

    if dry_run:
        print(f"  (dry-run) would write {len(cases)} case(s) to {_OUT / (task + '.jsonl')}")
        return task, len(cases), run_ids, times

    _OUT.mkdir(parents=True, exist_ok=True)
    path = _OUT / f"{task}.jsonl"
    with path.open("w") as fh:
        for c in cases:
            fh.write(json.dumps(c, default=str) + "\n")
    print(f"  wrote {len(cases)} case(s) -> {path}")
    return task, len(cases), run_ids, times


def _upload(cfg: dict, version: str):
    import boto3
    ds = cfg["dataset"]
    s3 = boto3.client(
        "s3",
        endpoint_url=ds["s3_endpoint_url"],
        aws_access_key_id=ds["access_key"],
        aws_secret_access_key=ds["secret_key"],
        region_name="us-east-1",
    )
    bucket = ds["bucket"]
    try:
        s3.head_bucket(Bucket=bucket)
    except Exception:
        s3.create_bucket(Bucket=bucket)
        print(f"created bucket {bucket}")
    for f in sorted(_OUT.iterdir()):
        key = f"datasets/{version}/{f.name}"
        s3.upload_file(str(f), bucket, key)
        print(f"uploaded s3://{bucket}/{key}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=f"v{dt.date.today():%Y%m%d}",
                    help="snapshot dir under datasets/ (default: v<today>)")
    ap.add_argument("--local-only", action="store_true", help="write ./dataset/ but skip MinIO upload")
    ap.add_argument("--dry-run", action="store_true", help="list matching runs, write nothing")
    args = ap.parse_args()

    cfg = _load_cfg()
    project = (cfg.get("langsmith") or {}).get("project")
    specs = (cfg.get("langsmith") or {}).get("export") or []
    if not project or not specs:
        sys.exit("config.yaml: langsmith.project and langsmith.export[] are required")
    if not os.environ.get("LANGCHAIN_API_KEY"):
        sys.exit("LANGCHAIN_API_KEY not set")

    from langsmith import Client
    client = Client()

    counts, all_run_ids, all_times = {}, {}, []
    for spec in specs:
        task, n, run_ids, times = _export_task(client, project, spec, args.dry_run)
        counts[task] = n
        all_run_ids[task] = run_ids
        all_times += times

    if args.dry_run:
        print(json.dumps({"counts": counts}, indent=2))
        return

    manifest = {
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "version": args.version,
        "source": f"langsmith:{project}",
        "counts": counts,
        "date_range": [min(all_times), max(all_times)] if all_times else None,
        "source_run_ids": all_run_ids,
    }
    (_OUT / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"wrote {_OUT / 'manifest.json'}  counts={counts}")

    if args.local_only:
        print("--local-only: skipping upload")
        return
    _upload(cfg, args.version)
    print(f"\ndone — set  dataset.version: {args.version}  in config.yaml")


if __name__ == "__main__":
    main()
