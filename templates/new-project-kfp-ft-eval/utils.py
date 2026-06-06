# Shared utility functions — inlined into model-loading components
# by scripts/build_pipeline.py at the # <<< UTILS_INJECT >>> marker.
# Do not add imports here that aren't available in the component container.


def parse_score(content):
    import json as _json, re as _re
    try:
        return float(_json.loads(content).get("score", 1))
    except Exception:
        m = _re.search(r'"score"\s*:\s*(\d+)', content)
        if m:
            return float(m.group(1))
        print(f"[parse_score] fallback triggered — could not parse: {content[:120]!r}")
        return 1.0


def _local_model_path(model_id):
    # IMPORTANT: always use this instead of passing model_id to from_pretrained().
    # The hf-model-cache PVC is read-only; passing model_id triggers hf_hub_download
    # which tries to write .locks/ and fails with PermissionError.
    import pathlib
    cache = pathlib.Path("/root/.cache/huggingface/hub")
    key = model_id.replace("/", "--")
    commit = (cache / f"models--{key}" / "refs" / "main").read_text().strip()
    return str(cache / f"models--{key}" / "snapshots" / commit)
