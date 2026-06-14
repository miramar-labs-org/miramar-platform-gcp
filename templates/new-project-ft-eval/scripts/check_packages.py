#!/usr/bin/env python3
"""Dry-run pip install for every component's packages_to_install.

Parses the compiled pipeline YAML, extracts each executor's (base_image,
packages) pair, and runs `docker run --rm <image> pip install --dry-run
<packages>`. Exits 1 if any conflict is detected, so deploy-to-kfp.yaml
catches dependency issues before submitting to KFP.

Note: images must be pullable from the runner. NGC images are large (~20 GB)
but are typically cached on the DGX after the first run.

Components that install packages via subprocess inside the function body
(e.g. to work around PIP_CONSTRAINT) are not checked here — those must be
validated manually or via a dedicated debug pod.
"""

import re
import subprocess
import sys

import yaml


def compile_pipeline(out="/tmp/pipeline_check.yaml"):
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).parent.parent))
    from kfp import compiler
    from pipeline import pipeline as pipe

    compiler.Compiler().compile(pipe, out)
    return out


def extract_image_packages(yaml_path):
    """Return list of (executor_name, image, [packages]) from compiled YAML."""
    results = []
    seen = set()
    for doc in yaml.safe_load_all(open(yaml_path)):
        if not doc or "deploymentSpec" not in doc:
            continue
        for name, comp in doc["deploymentSpec"]["executors"].items():
            c = comp.get("container", {})
            image = c.get("image", "")
            cmd = " ".join(c.get("command", []))
            # KFP renders packages_to_install as:
            #   python3 -m pip install --quiet --no-warn-script-location 'p1' 'p2' ... &&
            match = re.search(
                r"python3 -m pip install --quiet --no-warn-script-location (.*?) &&",
                cmd,
            )
            if not match:
                continue
            pkgs = re.findall(r"'([^']+)'", match.group(1))
            # Strip kfp internals always appended by the runner, and stray flags
            pkgs = [
                p for p in pkgs
                if not p.startswith("kfp")
                and not p.startswith("typing-extensions")
                and not p.startswith("-")
            ]
            if not pkgs:
                continue
            key = (image, tuple(sorted(pkgs)))
            if key in seen:
                continue
            seen.add(key)
            results.append((name, image, pkgs))
    return results


def dry_run(executor_name, image, packages):
    print(f"\n{'='*60}")
    print(f"Executor : {executor_name}")
    print(f"Image    : {image}")
    print(f"Packages : {packages}")
    print("=" * 60)
    result = subprocess.run(
        ["docker", "run", "--rm", image,
         "python3", "-m", "pip", "install", "--dry-run"] + packages,
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr
    conflict = result.returncode != 0 or "ResolutionImpossible" in output
    if conflict:
        # Print the relevant lines only
        for line in output.splitlines():
            if any(k in line for k in ("conflict", "Cannot install", "Resolution", "caused by", "requires", "Traceback")):
                print(line)
        return False
    print("OK")
    return True


def main():
    print("Compiling pipeline.py for package inspection...")
    yaml_path = compile_pipeline()

    combos = extract_image_packages(yaml_path)
    if not combos:
        print("No components with packages_to_install found — nothing to check.")
        return

    print(f"Found {len(combos)} unique (image, packages) combination(s) to check.")

    failed = []
    for name, image, pkgs in combos:
        if not dry_run(name, image, pkgs):
            failed.append(name)

    if failed:
        print(f"\nFAIL: pip dependency conflict(s) in: {', '.join(failed)}")
        print("Fix packages_to_install in the component decorator before deploying.")
        sys.exit(1)

    print(f"\nAll {len(combos)} combination(s) passed pip dry-run check.")


if __name__ == "__main__":
    main()
