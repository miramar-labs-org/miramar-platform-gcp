#!/usr/bin/env python3
"""Build pipeline.py from notebook.ipynb.

Reads every cell tagged kfp_step or kfp_pipeline and concatenates them into
a single pipeline.py file. Two inject markers are supported:

  # <<< PROCESSORS_INJECT >>>   — inlines the full content of processors.py
                                   (used in prepare_dataset)
  # <<< UTILS_INJECT >>>         — inlines the full content of utils.py
                                   (used in baseline_eval, post_finetune_eval)

The marker must be on its own line, indented with exactly 4 spaces (one level
inside a function body). The injected file is indented to the same depth.
"""

import json
import subprocess
import sys
import textwrap
from pathlib import Path

HERE = Path(__file__).parent.parent


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _strip_magic(src: str) -> str:
    """Remove IPython % magic lines — they are not valid Python."""
    return "".join(
        line for line in src.splitlines(keepends=True)
        if not line.lstrip().startswith("%")
    )


def build_pipeline(
    notebook_path: Path,
    processors_path: Path,
    utils_path: Path,
) -> Path:
    nb = json.loads(notebook_path.read_bytes())
    processors_src = _strip_magic(_read(processors_path))
    utils_src = _strip_magic(_read(utils_path))

    code_cells = []
    for cell in nb["cells"]:
        if cell["cell_type"] != "code":
            continue
        tags = cell.get("metadata", {}).get("tags", [])
        if "kfp_step" not in tags and "kfp_pipeline" not in tags:
            continue

        src = "".join(cell["source"])

        if "# <<< PROCESSORS_INJECT >>>" in src:
            src = src.replace(
                "    # <<< PROCESSORS_INJECT >>>",
                textwrap.indent(processors_src, "    "),
            )

        if "# <<< UTILS_INJECT >>>" in src:
            src = src.replace(
                "    # <<< UTILS_INJECT >>>",
                textwrap.indent(utils_src, "    "),
            )

        code_cells.append(src)

    pipeline_src = "\n\n\n".join(code_cells)
    out = HERE / "pipeline.py"
    out.write_text(pipeline_src, encoding="utf-8")
    print(f"Built {out}  ({len(code_cells)} cells, {len(pipeline_src)} chars)")
    return out


def main() -> None:
    build_pipeline(
        HERE / "notebook.ipynb",
        HERE / "processors.py",
        HERE / "utils.py",
    )


if __name__ == "__main__":
    main()
