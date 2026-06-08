"""
Re-generate pipeline.py from notebook.ipynb.  Also generates
docker/nsys_*.py standalone scripts for profiled container components.

Mirrors the Build cell in notebook.ipynb — run either one.
"""
import ast
import json
import pathlib
import re
import textwrap
import yaml


# ── parameter helpers ────────────────────────────────────────────────────────

_PARAM_RENAMES = {
    # param_name → argparse dest (underscore form for args.xxx; hyphens for --flag)
    "profile_warmup":      "warmup",
    "profile_capture":     "capture",
    "profile_max_steps":   "max_steps",
    "mlflow_tracking_uri": "mlflow_uri",
}


def _param_flag(name, ann_str):
    """Return the CLI --flag-name for a parameter."""
    if ann_str.startswith("Input[") or ann_str.startswith("Output["):
        return "--" + name.replace("_", "-") + "-path"
    dest = _PARAM_RENAMES.get(name, name)
    return "--" + dest.replace("_", "-")


def _param_attr(name, ann_str):
    """Return the args.xxx attribute name for a parameter."""
    if ann_str.startswith("Input[") or ann_str.startswith("Output["):
        return "args." + name + "_path"
    return "args." + _PARAM_RENAMES.get(name, name)


def _param_shell_var(name, ann_str):
    """Return the SHELL_VAR name used in the ContainerSpec bash script."""
    if ann_str.startswith("Input[") or ann_str.startswith("Output["):
        return name.upper() + "_PATH"
    return _PARAM_RENAMES.get(name, name).upper()


def _parse_params(src):
    """
    Parse the first FunctionDef in *src* and return a list of
    (name, ann_str, default_str) tuples.
    ann_str examples: "Input[Dataset]", "Output[Metrics]", "str", "int",
    "bool", "float", "list".  default_str is None when there is no default.
    """
    func_match = re.search(r"^def \w+\(", src, re.MULTILINE)
    if not func_match:
        return []
    try:
        tree = ast.parse(src[func_match.start():])
    except SyntaxError:
        return []
    func_def = next(
        (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)), None
    )
    if not func_def:
        return []

    defaults = func_def.args.defaults
    args_list = func_def.args.args
    default_offset = len(args_list) - len(defaults)
    params = []
    for i, arg in enumerate(args_list):
        name = arg.arg
        ann = arg.annotation
        di = i - default_offset
        default_str = ast.unparse(defaults[di]) if 0 <= di < len(defaults) else None
        if ann is None:
            ann_str = "str"
        elif isinstance(ann, ast.Subscript) and isinstance(ann.value, ast.Name):
            outer = ann.value.id
            inner = (
                ann.slice.id
                if isinstance(ann.slice, ast.Name)
                else ast.unparse(ann.slice)
            )
            ann_str = f"{outer}[{inner}]"
        elif isinstance(ann, ast.Name):
            ann_str = ann.id
        else:
            ann_str = ast.unparse(ann)
        params.append((name, ann_str, default_str))
    return params


def _build_argparse(params):
    """Return the module-level argparse block for an nsys_*.py script."""
    lines = [
        "import argparse as _ap",
        "_parser = _ap.ArgumentParser()",
    ]
    for name, ann_str, default_str in params:
        flag = _param_flag(name, ann_str)
        if ann_str.startswith("Input[") or ann_str.startswith("Output["):
            lines.append(f"_parser.add_argument({repr(flag)}, required=True)")
        elif ann_str == "int":
            d = f", default={default_str}" if default_str is not None else ", required=True"
            lines.append(f"_parser.add_argument({repr(flag)}, type=int{d})")
        elif ann_str == "float":
            d = f", default={default_str}" if default_str is not None else ", required=True"
            lines.append(f"_parser.add_argument({repr(flag)}, type=float{d})")
        elif ann_str == "bool":
            d = f", default={default_str}" if default_str is not None else ", required=True"
            lines.append(
                f"_parser.add_argument({repr(flag)}, "
                f"type=lambda x: x.lower() == 'true'{d})"
            )
        elif ann_str == "list":
            if default_str is not None:
                lines.append(
                    f"_parser.add_argument({repr(flag)}, type=__import__('json').loads, "
                    f"default=__import__('json').loads({repr(default_str)}))"
                )
            else:
                lines.append(
                    f"_parser.add_argument({repr(flag)}, "
                    f"type=__import__('json').loads, required=True)"
                )
        else:  # str
            d = f", default={default_str}" if default_str is not None else ", required=True"
            lines.append(f"_parser.add_argument({repr(flag)}{d})")
    lines.append("args = _parser.parse_args()")
    return "\n".join(lines)


def _apply_subs(body, params):
    """
    Replace KFP parameter references with args.xxx equivalents.

    Runs on the ORIGINAL (uninjected) component body so that injected helper
    function definitions are never affected.

    Two precautions against over-substitution:
      • negative lookbehind (?<!args\\.)  — prevents double-substitution
      • negative lookahead  (?!\\s*=)     — does NOT substitute keyword arg names
                                            (e.g. keeps `max_new_tokens=` intact)
    """
    # Phase 1: artifact .path accesses  (literal replace, longest first)
    for name, ann_str, _ in params:
        if ann_str.startswith("Input[") or ann_str.startswith("Output["):
            body = body.replace(f"{name}.path", f"args.{name}_path")

    # Phase 2: primitive names (word-boundary, longest-match, skip kwarg keys)
    prim = {
        name: _param_attr(name, ann_str)
        for name, ann_str, _ in params
        if not ann_str.startswith("Input[") and not ann_str.startswith("Output[")
    }
    if prim:
        pattern = (
            r"(?<!args\.)(?<!\.)\b("
            + "|".join(re.escape(k) for k in sorted(prim, key=len, reverse=True))
            + r")\b(?!\s*=)"          # skip keyword arg keys (e.g. `bf16=`)
        )
        body = re.sub(pattern, lambda m: prim[m.group(1)], body)
    return body


def _extract_body_raw(src, func_name):
    """
    Extract the function body from the ORIGINAL (uninjected) source.
    Returns the dedented body text (still contains <<< INJECT >>> markers).
    """
    try:
        tree = ast.parse(src)
    except SyntaxError as exc:
        raise RuntimeError(f"SyntaxError parsing {func_name}: {exc}") from exc

    func_def = next(
        (n for n in ast.walk(tree)
         if isinstance(n, ast.FunctionDef) and n.name == func_name),
        None,
    )
    if func_def is None:
        raise RuntimeError(f"FunctionDef '{func_name}' not found")

    body_lineno = func_def.body[0].lineno - 1  # 0-indexed
    lines = src.split("\n")
    return textwrap.dedent("\n".join(lines[body_lineno:]))


def _inject_helpers(body, utils_src, eval_helpers_src):
    """Replace <<< INJECT >>> markers with the actual helper source."""
    if "# <<< UTILS_INJECT >>>" in body:
        body = body.replace("# <<< UTILS_INJECT >>>", utils_src)
    if "# <<< EVAL_HELPERS_INJECT >>>" in body:
        body = body.replace("# <<< EVAL_HELPERS_INJECT >>>", eval_helpers_src)
    return body


def _inject_cuda_profiler(body, func_name):
    """
    Wrap the capture window with nvtx.push_range("nsys_capture") / nvtx.pop_range().

    nsys uses NVTX interception (via LD_PRELOAD of libnvtx) which is reliable.
    The previous approach used torch.cuda.cudart().cudaProfilerStart/Stop(), which
    calls into PyTorch's compiled-in _C._cudart module — bypassing nsys's
    LD_PRELOAD / CUDA injection interception — so nsys never saw the signal.

    Three strategies:
      A. Has '# <<< PROFILED_STOP >>>'  → wrap the 'with nvtx.annotate(' block
      B. Has 'trainer.train()'          → wrap the train call
      C. Has 'for i, row in enumerate'  → wrap the inference loop
    """
    lines = body.split("\n")

    # ── Strategy A ──────────────────────────────────────────────────────────
    if "# <<< PROFILED_STOP >>>" in body:
        nvtx_idx = next(
            (i for i, ln in enumerate(lines) if re.search(r"with nvtx\.annotate\(", ln)),
            None,
        )
        if nvtx_idx is None:
            return body
        indent = re.match(r"^(\s*)", lines[nvtx_idx]).group(1)
        sync_idx = next(
            (i for i, ln in enumerate(lines)
             if i > nvtx_idx and "torch.cuda.synchronize()" in ln),
            None,
        )
        result = []
        for i, ln in enumerate(lines):
            if i == nvtx_idx:
                result.append(f"{indent}nvtx.push_range('nsys_capture')")
            result.append(ln)
            if sync_idx is not None and i == sync_idx:
                result.append(f"{indent}nvtx.pop_range()")
        return "\n".join(result)

    # ── Strategy B ──────────────────────────────────────────────────────────
    if "trainer.train()" in body:
        train_idx = next(
            (i for i, ln in enumerate(lines) if "trainer.train()" in ln), None
        )
        if train_idx is None:
            return body
        indent = re.match(r"^(\s*)", lines[train_idx]).group(1)
        result = []
        for i, ln in enumerate(lines):
            if i == train_idx:
                result.append(f"{indent}nvtx.push_range('nsys_capture')")
                result.append(f"{indent}with nvtx.annotate('finetune_training'):")
                result.append(f"{indent}    {ln.lstrip()}")
                result.append(f"{indent}torch.cuda.synchronize()")
                result.append(f"{indent}nvtx.pop_range()")
            else:
                result.append(ln)
        return "\n".join(result)

    # ── Strategy C ──────────────────────────────────────────────────────────
    loop_idx = next(
        (i for i, ln in enumerate(lines)
         if re.search(r"for i, row in enumerate\(", ln)),
        None,
    )
    if loop_idx is None:
        return body
    indent = re.match(r"^(\s*)", lines[loop_idx]).group(1)
    loop_end_idx = len(lines)
    for i in range(loop_idx + 1, len(lines)):
        ln = lines[i]
        if not ln.strip():
            continue
        li = re.match(r"^(\s*)", ln).group(1)
        if len(li) <= len(indent):
            loop_end_idx = i
            break
    result = []
    for i, ln in enumerate(lines):
        if i == loop_idx:
            result.append(f"{indent}nvtx.push_range('nsys_capture')")
        result.append(ln)
        if i == loop_end_idx - 1:
            result.append(f"{indent}nvtx.pop_range()")
    return "\n".join(result)


def _metrics_suffix(body, func_name):
    """
    Return (body_trimmed, accuracy_expr) where body_trimmed is the body up to
    (but not including) the KFP Metrics artifact write, and accuracy_expr is
    the Python expression that yields _profiling_accuracy.

    Also strips the existing plain-JSON metrics write from safety-eval bodies.
    """
    STOP = "# <<< PROFILED_STOP >>>"

    if STOP in body:
        stop_idx = body.index(STOP)
        body_trimmed = body[:stop_idx].rstrip()
        # The PROFILED_STOP marker sits inside the `with mlflow.start_run():` block
        # (4-space indent after dedent). Keep the accuracy block at 4-space indent so
        # it runs inside the same context and can call mlflow.log_metric.
        accuracy_block = (
            "\n\n"
            "    # ── profiling accuracy (second pass over capture window) ──────\n"
            "    _cap_correct = sum(\n"
            "        1 for _r in val_data[WARMUP:WARMUP + CAPTURE]\n"
            "        if extract_answer(_infer(_r)) == extract_answer(_r['response'])\n"
            "    ) if CAPTURE > 0 else 0\n"
            "    _profiling_accuracy = _cap_correct / CAPTURE if CAPTURE > 0 else 0.0\n"
            "    mlflow.log_metric('baseline_accuracy', _profiling_accuracy)\n"
        )
        return body_trimmed, accuracy_block

    if "trainer.train()" in body:
        accuracy_block = (
            "\n\n"
            "# ── profiling metric (train loss proxy) ────────────────────────\n"
            "_profiling_accuracy = float(train_loss) if train_loss is not None else 0.0\n"
        )
        return body, accuracy_block

    # Safety eval: avg_score already computed; strip write_text call to end of body.
    # write_text is always the last statement and may have nested parens (json.dumps),
    # so we strip from the pathlib.Path line to end-of-string rather than trying to
    # match balanced parentheses with a regex.
    body_trimmed = re.sub(
        r"\n?pathlib\.Path\(args\.metrics_path\)\.write_text\(.*",
        "",
        body,
        flags=re.DOTALL,
    )
    accuracy_block = (
        "\n\n"
        "# ── profiling metric (safety score proxy) ──────────────────────\n"
        "_profiling_accuracy = float(avg_score) if avg_score is not None else 0.0\n"
    )
    return body_trimmed, accuracy_block


def _generate_nsys_script(
    func_name, src_orig, stage_name, nsys_project, utils_src, eval_helpers_src
):
    """
    Generate docker/nsys_{func_name}.py from the ORIGINAL (uninjected) KFP
    component source.  Substitutions run before helpers are inlined so that
    helper function definitions are never mutated.

    Returns True on success, False if skipped (no body found).
    """
    params = _parse_params(src_orig)
    if not params:
        return False

    # fine_tune has no metrics output — add one for the standalone script
    if not any(n == "metrics" for n, _, _ in params):
        params.append(("metrics", "Output[Metrics]", None))

    try:
        body = _extract_body_raw(src_orig, func_name)
    except RuntimeError:
        return False

    # Substitutions on the original body (no helper defs present yet)
    body = _apply_subs(body, params)

    # Now inline helpers
    body = _inject_helpers(body, utils_src, eval_helpers_src)

    # Inject nvtx.push_range/pop_range capture window
    body = _inject_cuda_profiler(body, func_name)

    # Trim body to profiling section and compute accuracy block
    body, accuracy_block = _metrics_suffix(body, func_name)

    metrics_write = (
        "\n\n"
        "# ── write KFP Metrics artifact ─────────────────────────────────\n"
        "import pathlib as _pl\n"
        "_pl.Path(args.metrics_path).parent.mkdir(parents=True, exist_ok=True)\n"
        "_pl.Path(args.metrics_path).write_text(\n"
        "    '{\"metrics\": [{\"name\": \"profiling_accuracy\", \"numberValue\": '\n"
        "    + str(_profiling_accuracy) + '}]}'\n"
        ")\n"
    )

    script = "\n".join([
        "#!/usr/bin/env python3",
        f"# Generated by build_pipeline.py — stage: {stage_name}",
        f"# nsys project: {nsys_project}",
        "",
        _build_argparse(params),
        "",
        "# ── component body ───────────────────────────────────────────────",
        body,
        accuracy_block,
        metrics_write,
    ])

    out_path = pathlib.Path("docker") / f"nsys_{func_name}.py"
    out_path.write_text(script)
    return True


def _make_container_component(func_name, src_orig, profiled_image, nsys_project, stage_name):
    """
    Return Python source for a @dsl.container_component that runs
    nsys_{func_name}.py under nsys profile using a bash -lc wrapper.
    """
    params = _parse_params(src_orig)

    # fine_tune: add metrics output if absent
    if not any(n == "metrics" for n, _, _ in params):
        params.append(("metrics", "Output[Metrics]", None))

    # Positional order for ContainerSpec args: run_id first ($0), then declaration order
    ordered = sorted(params, key=lambda p: 0 if p[0] == "run_id" else 1)

    # Signature order: required (no default) first, optional (has default) last.
    # Python requires this; the ContainerSpec positional order uses `ordered`.
    sig_params = (
        [p for p in params if p[2] is None]
        + [p for p in params if p[2] is not None]
    )

    # ── shell variable assignments ─────────────────────────────────────────
    shell_lines = []
    for idx, (name, ann_str, _) in enumerate(ordered):
        var = _param_shell_var(name, ann_str)
        ref = f"${{{idx}}}" if idx >= 10 else f"${idx}"
        shell_lines.append(f'{var}="{ref}"')

    # ── python CLI args (named flags, any order) ───────────────────────────
    py_arg_lines = []
    for name, ann_str, _ in params:
        flag = _param_flag(name, ann_str)
        var  = _param_shell_var(name, ann_str)
        py_arg_lines.append(f'    {flag} "${{{var}}}"')

    # Embed the generated nsys script as a base64 blob so the image doesn't
    # need to contain project-specific scripts.  The script is decoded and
    # written to /tmp at container startup — no image rebuild needed when the
    # profiling code changes.
    import base64 as _base64
    _script_path = pathlib.Path("docker") / f"nsys_{func_name}.py"
    _script_b64 = _base64.b64encode(_script_path.read_bytes()).decode()
    _script_tmp = f"/tmp/nsys_{func_name}.py"
    _decode_cmd = (
        f"python3 -c 'import base64,pathlib;"
        f" pathlib.Path(\"{_script_tmp}\").write_bytes("
        f"base64.b64decode(\"{_script_b64}\"))'\n"
    )

    shell_script = (
        "set -euo pipefail\n"
        # umask 000 ensures all dirs created by mkdir -p are world-writable (777).
        # Required because the pod runs as UID 65532 but the minikube 9p mount presents
        # ownership relative to the host UID (1000/aaron), so without 777 the pod
        # cannot write into directories it created on the shared hostPath volume.
        + "umask 000\n"
        # NVIDIA_DRIVER_CAPABILITIES: the NGC pytorch base image sets compute,utility,video.
        # 'all' is required to mount the CUPTI profiling libraries into the container.
        # NVIDIA_VISIBLE_DEVICES: force 'all' to prevent any env override from hiding the GPU.
        # Both are required for nsys CUPTI to attach on DGX Spark (Blackwell GB10).
        + "export NVIDIA_DRIVER_CAPABILITIES=all\n"
        + "export NVIDIA_VISIBLE_DEVICES=all\n"
        + "\n".join(shell_lines) + "\n"
        # Decode the nsys script from the base64 blob embedded at compile time.
        # This removes the dependency on the image containing project-specific scripts.
        + _decode_cmd
        + f'PROFILE_DIR="/nsight-reports/{nsys_project}/${{RUN_ID}}/{stage_name}"\n'
        + 'mkdir -p "${PROFILE_DIR}"\n'
        # nsys writes .nsys-rep via mmap-based FileStream; the 9p noextend mount used
        # by minikube hostPath PVCs does not support mmap writes (EACCES).  Write to
        # /tmp (local tmpfs, always writable) then cp to the shared volume.
        # osrt omitted: on GB10 Blackwell it suppresses cuda_gpu_kern_sum capture.
        + "nsys profile \\\n"
        + "  --trace=cuda,nvtx,cublas,cudnn \\\n"
        + "  --cuda-flush-interval=10000 \\\n"
        + "  --sample=none --force-overwrite=true \\\n"
        + '  -o "/tmp/nsys_profile" \\\n'
        + f"  python3 {_script_tmp} \\\n"
        + " \\\n".join(py_arg_lines) + "\n"
        # Run stats against /tmp BEFORE copying to PVC — the 9p filesystem has
        # 1-second mtime resolution; copying nsys-rep and then generating sqlite
        # in the same second causes "sqlite older than input" false positive.
        + 'nsys stats /tmp/nsys_profile.nsys-rep > /tmp/nsys_stats.txt || true\n'
        # Generate per-report summaries consumed by the /nsight-interpret skill.
        # Each section is prefixed with "=== <report_name> ===" for direct reading.
        # --format csv is intentionally omitted: some reports reject it (exit 1).
        + '{ for _r in cuda_gpu_kern_sum cuda_api_sum cuda_gpu_mem_time_sum cuda_gpu_mem_size_sum nvtx_sum; do\n'
        + '    echo "=== ${_r} ==="; nsys stats --report "${_r}" /tmp/nsys_profile.nsys-rep 2>&1 || echo "(skipped)";\n'
        + 'done; } > /tmp/summaries.csv || true\n'
        # Copy all artifacts to PVC after stats are done
        + 'cp /tmp/nsys_profile.nsys-rep "${PROFILE_DIR}/profile.nsys-rep"\n'
        + 'cp /tmp/nsys_profile.sqlite "${PROFILE_DIR}/profile.sqlite" 2>/dev/null || true\n'
        + 'cp /tmp/nsys_stats.txt "${PROFILE_DIR}/nsys_stats.txt" 2>/dev/null || true\n'
        + 'cp /tmp/summaries.csv "${PROFILE_DIR}/summaries.csv"\n'
    )

    # ── Python function signature (required params first, optional last) ───
    sig_parts = []
    for name, ann_str, default_str in sig_params:
        if default_str is not None:
            sig_parts.append(f"    {name}: {ann_str} = {default_str}")
        else:
            sig_parts.append(f"    {name}: {ann_str}")
    sig = ",\n".join(sig_parts)

    # ── ContainerSpec args list ────────────────────────────────────────────
    container_args = []
    for name, ann_str, _ in ordered:
        if ann_str.startswith("Input[") or ann_str.startswith("Output["):
            container_args.append(f"            {name}.path,")
        else:
            container_args.append(f"            {name},")
    container_args_str = "\n".join(container_args)

    return (
        f"@dsl.container_component\n"
        f"def {func_name}_profiled(\n"
        f"{sig},\n"
        f"):\n"
        f"    return dsl.ContainerSpec(\n"
        f"        image={repr(profiled_image)},\n"
        f"        command=['bash', '-lc'],\n"
        f"        args=[\n"
        f"            {repr(shell_script)},\n"
        f"{container_args_str}\n"
        f"        ],\n"
        f"    )\n"
    )


# ── main builder ─────────────────────────────────────────────────────────────

def build_pipeline(
    notebook_path="notebook.ipynb",
    formatters_path="formatters.py",
    loaders_path="loaders.py",
    eval_helpers_path="eval_helpers.py",
    utils_path="utils.py",
    config_path="config.yaml",
):
    base_dir = pathlib.Path(notebook_path).parent
    cfg = yaml.safe_load((base_dir / config_path).read_text())
    _nsys_project = cfg.get("nsys_project", "project")
    nb = json.loads(pathlib.Path(notebook_path).read_text())
    formatters_src   = (base_dir / formatters_path).read_text().rstrip("\n")
    loaders_src      = (base_dir / loaders_path).read_text().rstrip("\n")
    eval_helpers_src = (base_dir / eval_helpers_path).read_text().rstrip("\n")
    utils_src        = (base_dir / utils_path).read_text().rstrip("\n")

    pathlib.Path("docker").mkdir(exist_ok=True)

    step_srcs, pipeline_src = [], None
    for cell in nb["cells"]:
        if cell["cell_type"] != "code":
            continue
        tags = cell.get("metadata", {}).get("tags", [])
        meta = cell.get("metadata", {})
        src_orig = "".join(cell["source"])

        if "kfp_step" in tags:
            profiled_image = meta.get("profiled_image")

            # Generate nsys script + container component BEFORE injections
            # so that helper-function bodies are never subjected to substitution.
            if profiled_image:
                m = re.search(r"^def (\w+)\(", src_orig, re.MULTILINE)
                if m:
                    fname = m.group(1)
                    stage_name = fname.replace("_", "-")
                    _generate_nsys_script(
                        fname, src_orig, stage_name, _nsys_project,
                        utils_src, eval_helpers_src,
                    )
                    step_srcs.append(
                        _make_container_component(
                            fname, src_orig, profiled_image, _nsys_project, stage_name
                        )
                    )

            # Now apply injections for the KFP component source
            src = src_orig
            if "# <<< FORMATTERS_INJECT >>>" in src:
                src = src.replace(
                    "    # <<< FORMATTERS_INJECT >>>",
                    textwrap.indent(formatters_src, "    "),
                )
            if "# <<< LOADERS_INJECT >>>" in src:
                src = src.replace(
                    "    # <<< LOADERS_INJECT >>>",
                    textwrap.indent(loaders_src, "    "),
                )
            if "# <<< EVAL_HELPERS_INJECT >>>" in src:
                src = src.replace(
                    "    # <<< EVAL_HELPERS_INJECT >>>",
                    textwrap.indent(eval_helpers_src, "    "),
                )
            if "# <<< UTILS_INJECT >>>" in src:
                src = src.replace(
                    "    # <<< UTILS_INJECT >>>",
                    textwrap.indent(utils_src, "    "),
                )
            step_srcs.append(src)

        elif "kfp_pipeline" in tags:
            pipeline_src = src_orig

    if not step_srcs:
        raise RuntimeError("No cells tagged 'kfp_step' found.")
    if pipeline_src is None:
        raise RuntimeError("No cell tagged 'kfp_pipeline' found.")

    names = [
        m.group(1)
        for s in step_srcs
        for m in [re.search(r"^def (\w+)\(", s, re.MULTILINE)]
        if m
    ]

    out  = "# Generated by notebook.ipynb — do not edit manually.\n"
    out += "# Re-run the Build cell (or scripts/build_pipeline.py) to regenerate.\n\n"
    out += "from kfp import dsl\n"
    out += "from kfp.dsl import Input, Output, Dataset, Model, Metrics, Artifact\n\n\n"
    out += "\n\n\n".join(step_srcs)
    out += "\n\n\n"
    out += pipeline_src
    out += "\n"
    pathlib.Path("pipeline.py").write_text(out)
    print(f"Wrote pipeline.py — {len(names)} component(s): {', '.join(names)}")
    docker_scripts = sorted(pathlib.Path("docker").glob("nsys_*.py"))
    if docker_scripts:
        print(
            f"Wrote {len(docker_scripts)} nsys script(s): "
            + ", ".join(p.name for p in docker_scripts)
        )


if __name__ == "__main__":
    build_pipeline()
