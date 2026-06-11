#!/usr/bin/env python3
"""
Build pipeline.py from notebook, compile, register in KFP, and submit a run.

Usage:
  python3 scripts/deploy_pipeline.py --run-name run-015

Env vars (override CLI):
  KFP_HOST   - KFP API server URL  (default: http://localhost:8890)
  RUN_NAME   - display name for the run (default: pipeline-run)
"""
import argparse
import importlib.util
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-name", default=None,
                        help="KFP run display name (also sets run_id pipeline param)")
    parser.add_argument("--host", default=None, help="KFP API server URL")
    parser.add_argument("--chunk-index", type=int, default=None,
                        help="Chunk index for multi-run chunked training (overrides config.yaml chunking.chunk_index)")
    args = parser.parse_args()

    host = args.host or os.environ.get("KFP_HOST", "http://localhost:8890")
    run_name = args.run_name or os.environ.get("RUN_NAME", "pipeline-run")

    # Load config to resolve chunk_index default and validate chunking config
    import yaml as _yaml
    _cfg_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.yaml")
    _cfg = (_yaml.safe_load(open(_cfg_path).read()) or {}) if os.path.exists(_cfg_path) else {}
    _chunking = _cfg.get("chunking", {})
    chunk_index = args.chunk_index if args.chunk_index is not None else _chunking.get("chunk_index", 0)

    # ── Always rebuild pipeline.py from notebook ──────────────────────────
    from scripts.build_pipeline import build_pipeline
    build_pipeline()

    # ── Import freshly-built pipeline (dynamic to avoid stale cache) ──────
    spec = importlib.util.spec_from_file_location("pipeline", "pipeline.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    pipeline_fn = mod.pipeline

    # ── Compile ───────────────────────────────────────────────────────────
    from kfp import compiler
    import yaml as _yaml
    pipeline_yaml = "/tmp/compiled-pipeline.yaml"
    pipeline_name = os.path.basename(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
    # ── Download model to HF cache ────────────────────────────────────────────
    # huggingface-cli download is idempotent — skips files already present.
    import pathlib as _pl
    _hf_base = os.path.expanduser("~/shared/huggingface-kfp")
    _model_id = (_cfg.get("model") or {}).get("id", "")
    if _model_id and _model_id != "org/model":
        _hf_hub = _pl.Path(_hf_base)
        print(f"Downloading model: {_model_id}")
        from huggingface_hub import snapshot_download as _snapshot_download
        _snapshot_download(repo_id=_model_id, cache_dir=str(_hf_hub),
                           token=os.environ.get("HF_TOKEN"))

    compiler.Compiler().compile(pipeline_func=pipeline_fn, package_path=pipeline_yaml)
    print(f"Compiled: {pipeline_yaml}")

    # ── Load project description ──────────────────────────────────────────
    _cfg_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.yaml")
    pipeline_description = None
    if os.path.exists(_cfg_path):
        pipeline_description = (_yaml.safe_load(open(_cfg_path).read()) or {}).get("description") or None

    # ── Register + submit ─────────────────────────────────────────────────
    import kfp
    client = kfp.Client(host=host)

    try:
        client.upload_pipeline(
            pipeline_package_path=pipeline_yaml,
            pipeline_name=pipeline_name,
            description=pipeline_description,
        )
        print(f"Pipeline registered: {pipeline_name}")
    except Exception as e:
        print(f"Note: pipeline registration skipped ({type(e).__name__})",
              file=sys.stderr)

    try:
        client.create_experiment(pipeline_name, description=pipeline_description)
        print(f"KFP experiment created: {pipeline_name}")
    except Exception:
        pass  # already exists

    if pipeline_description:
        try:
            import urllib.request as _ureq, urllib.error as _uerr, json as _json
            _mlflow_uri = os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000")
            def _mlflow_api(method, path, body=None):
                _data = _json.dumps(body).encode() if body else None
                _r = _ureq.Request(f"{_mlflow_uri}/api/2.0/mlflow{path}", data=_data,
                                   headers={"Content-Type": "application/json"}, method=method)
                with _ureq.urlopen(_r, timeout=5) as _resp:
                    return _json.loads(_resp.read())
            try:
                _exp_id = _mlflow_api("POST", "/experiments/create", {"name": pipeline_name})["experiment_id"]
            except _uerr.HTTPError as _e:
                if _e.code == 400:
                    _exp_id = _mlflow_api("GET", f"/experiments/get-by-name?experiment_name={pipeline_name}")["experiment"]["experiment_id"]
                else:
                    raise
            _mlflow_api("POST", "/experiments/set-experiment-tag",
                        {"experiment_id": _exp_id, "key": "mlflow.note.content", "value": pipeline_description})
            print(f"MLflow experiment description set: {pipeline_name}")
        except Exception as e:
            print(f"Note: could not set MLflow experiment description ({e})", file=sys.stderr)

    run_response = client.create_run_from_pipeline_package(
        pipeline_file=pipeline_yaml,
        arguments={"run_id": run_name, "mlflow_experiment_name": pipeline_name,
                   "chunk_index": chunk_index},
        run_name=run_name,
        experiment_name=pipeline_name,
    )
    run_id = run_response.run_id
    print(f"Run submitted — ID: {run_id}")
    print(f"UI: {host}/#/runs/details/{run_id}")

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"run_id={run_id}\n")


if __name__ == "__main__":
    main()
