#!/usr/bin/env python3
"""
Build pipeline.py from notebook, copy input data to PVC, compile, register in KFP, and submit a run.

Usage:
  python3 scripts/deploy_pipeline.py --run-name run-001

Env vars (override CLI):
  KFP_HOST   - KFP API server URL  (default: http://localhost:8890)
  RUN_NAME   - display name for the run (default: pipeline-run)
"""
import argparse
import importlib.util
import os
import pathlib
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Host-side PVC root — matches the k3s hostPath for hf-model-cache PVC.
_PVC_HOST_ROOT = pathlib.Path(os.path.expanduser("~/shared/huggingface-kfp"))
_PROJECT_ROOT = pathlib.Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _prepare_stage_dirs(project_name: str):
    """Pre-create all 5 stage dirs with mode 0o777.

    KFP pods run as uid=0 with capabilities.drop:[ALL], which removes DAC_OVERRIDE.
    Without DAC_OVERRIDE, even root cannot write to directories owned by another uid
    (uid=1000 here) with mode 755. Creating and chmod-ing them here (as uid=1000 in
    the runner) ensures the container can write regardless of capability restrictions.
    preflight_check verifies writability and fails fast if this step was skipped.
    """
    project_dir = _PVC_HOST_ROOT / "curator-input" / project_name
    for subdir in ["raw", "extracted", "quality_filtered", "deduped", "curated"]:
        d = project_dir / subdir
        d.mkdir(parents=True, exist_ok=True)
        d.chmod(0o777)
    print(f"Stage dirs pre-created (chmod 777): {project_dir}/")


def _upsert_mlflow_artifact_secret():
    """Upsert mlflow-artifact-env secret in kubeflow namespace.

    KFP pods that call mlflow.log_dict need MinIO credentials — the upload goes
    directly from the pod to MinIO via boto3, not through the tracking server.
    Reads creds from mlflow-system to avoid hardcoding.
    """
    import subprocess, json, base64

    def _kubectl_json(*args):
        r = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True)
        return json.loads(r.stdout) if r.returncode == 0 else None

    secret = _kubectl_json("get", "secret", "mlflow-tracking-env-secret", "-n", "mlflow-system")
    if not secret:
        print("WARNING: mlflow-tracking-env-secret not found — skipping artifact secret upsert",
              file=sys.stderr)
        return
    creds = {k: base64.b64decode(v).decode() for k, v in secret["data"].items()}

    deploy = _kubectl_json("get", "deployment", "mlflow-tracking", "-n", "mlflow-system")
    env_map = {}
    if deploy:
        for c in deploy["spec"]["template"]["spec"]["containers"]:
            for e in c.get("env", []):
                if "value" in e:
                    env_map[e["name"]] = e["value"]

    from_literals = [
        f"--from-literal=AWS_ACCESS_KEY_ID={creds.get('AWS_ACCESS_KEY_ID', '')}",
        f"--from-literal=AWS_SECRET_ACCESS_KEY={creds.get('AWS_SECRET_ACCESS_KEY', '')}",
        f"--from-literal=AWS_DEFAULT_REGION={env_map.get('AWS_DEFAULT_REGION', 'us-east-1')}",
        f"--from-literal=AWS_S3_FORCE_PATH_STYLE={env_map.get('AWS_S3_FORCE_PATH_STYLE', 'true')}",
        f"--from-literal=MLFLOW_S3_ENDPOINT_URL={env_map.get('MLFLOW_S3_ENDPOINT_URL', '')}",
        f"--from-literal=MLFLOW_S3_IGNORE_TLS={env_map.get('MLFLOW_S3_IGNORE_TLS', 'true')}",
    ]
    create = subprocess.run(
        ["kubectl", "create", "secret", "generic", "mlflow-artifact-env",
         "-n", "kubeflow", "--dry-run=client", "-o", "yaml"] + from_literals,
        capture_output=True, text=True,
    )
    if create.returncode != 0:
        print(f"WARNING: could not generate mlflow-artifact-env yaml: {create.stderr}", file=sys.stderr)
        return
    apply = subprocess.run(["kubectl", "apply", "-f", "-"],
                           input=create.stdout, capture_output=True, text=True)
    if apply.returncode != 0:
        print(f"WARNING: could not upsert mlflow-artifact-env secret: {apply.stderr}", file=sys.stderr)
    else:
        print(f"mlflow-artifact-env secret upserted in kubeflow namespace")


def _copy_inputs_to_pvc(project_name: str):
    """Copy data_src/ contents to the PVC raw input directory before submitting."""
    dest = _PVC_HOST_ROOT / "curator-input" / project_name / "raw"

    data_src = _PROJECT_ROOT / "data_src"
    if data_src.exists() and any(f for f in data_src.rglob("*") if f.is_file() and not f.name.startswith(".")):
        for f in data_src.rglob("*"):
            if f.is_file() and not f.name.startswith(".") and f.name != "README.md":
                rel = f.relative_to(data_src)
                target = dest / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, target)
        n_files = sum(1 for _ in dest.rglob("*") if _.is_file())
        print(f"Copied {n_files} file(s) from data_src/ → {dest}/")
    else:
        print(
            "WARNING: data_src/ is empty (or contains only README.md) — "
            "preflight_check will fail.\n"
            "Add source documents to data_src/ before deploying.",
            file=sys.stderr,
        )

    print(f"PVC input dir: {dest}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-name", default=None,
                        help="KFP run display name (also sets run_id pipeline param)")
    parser.add_argument("--host", default=None, help="KFP API server URL")
    args = parser.parse_args()

    host = args.host or os.environ.get("KFP_HOST", "http://localhost:8890")
    run_name = args.run_name or os.environ.get("RUN_NAME", "pipeline-run")

    import yaml as _yaml
    _cfg_path = _PROJECT_ROOT / "config.yaml"
    _cfg = _yaml.safe_load(_cfg_path.read_text()) if _cfg_path.exists() else {}

    pipeline_name = _PROJECT_ROOT.name

    # ── Upsert MinIO artifact credentials secret ──────────────────────────
    _upsert_mlflow_artifact_secret()

    # ── Prepare stage dirs + copy input data to PVC ──────────────────────
    if _PVC_HOST_ROOT.exists():
        _prepare_stage_dirs(pipeline_name)
        _copy_inputs_to_pvc(pipeline_name)
    else:
        print(f"WARNING: PVC host root not found at {_PVC_HOST_ROOT} — skipping input copy",
              file=sys.stderr)

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
    pipeline_yaml = "/tmp/compiled-pipeline.yaml"
    compiler.Compiler().compile(pipeline_func=pipeline_fn, package_path=pipeline_yaml)
    print(f"Compiled: {pipeline_yaml}")

    # ── Load project description ──────────────────────────────────────────
    pipeline_description = (_cfg or {}).get("description") or None

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
        print(f"Note: pipeline registration skipped ({type(e).__name__})", file=sys.stderr)

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
                _exp_id = _mlflow_api("POST", "/experiments/create",
                                      {"name": pipeline_name})["experiment_id"]
            except _uerr.HTTPError as _e:
                if _e.code == 400:
                    _exp = _mlflow_api("GET", f"/experiments/get-by-name?experiment_name={pipeline_name}").get("experiment")
                    if _exp:
                        _exp_id = _exp["experiment_id"]
                    else:
                        raise
                else:
                    raise
            _mlflow_api("POST", "/experiments/set-experiment-tag",
                        {"experiment_id": _exp_id, "key": "mlflow.note.content",
                         "value": pipeline_description})
            print(f"MLflow experiment description set: {pipeline_name}")
        except Exception as e:
            print(f"Note: could not set MLflow experiment description ({e})", file=sys.stderr)

    run_response = client.create_run_from_pipeline_package(
        pipeline_file=pipeline_yaml,
        arguments={"run_id": run_name, "mlflow_experiment_name": pipeline_name},
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
