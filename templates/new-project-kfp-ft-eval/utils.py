# Shared utility functions — inlined into model-loading components
# by scripts/build_pipeline.py at the # <<< UTILS_INJECT >>> marker.
# Do not add imports here that aren't available in the component container.


def _local_model_path(model_id):
    # IMPORTANT: always use this instead of passing model_id to from_pretrained().
    # The hf-model-cache PVC is read-only; passing model_id triggers hf_hub_download
    # which tries to write .locks/ and fails with PermissionError.
    import pathlib
    cache = pathlib.Path("/root/.cache/huggingface/hub")
    key = model_id.replace("/", "--")
    commit = (cache / f"models--{key}" / "refs" / "main").read_text().strip()
    return str(cache / f"models--{key}" / "snapshots" / commit)
