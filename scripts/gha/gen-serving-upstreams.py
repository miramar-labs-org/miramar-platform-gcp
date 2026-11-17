#!/usr/bin/env python3
"""Generate LiteLLM upstream entries for every serving project running in the cluster.

Serving projects (serving-vllm, serving-trt-engine, ...) used to register by
committing their entry to litellm-config.yaml through the GitHub Contents API.
That needed a token with write access to this repo inside every (public) serving
repo, and it stopped working once `main` required pull requests (Nov 2026
incident). Instead, a serving deploy labels and annotates its own Service:

    metadata:
      labels:
        miramar.ai/router: "true"
      annotations:
        miramar.ai/router-model: <served_model_name>        # LiteLLM model_name
        miramar.ai/router-litellm-model: openai/<name>      # litellm_params.model
        miramar.ai/router-api-base: http://<svc>.<ns>.svc.cluster.local:8000/v1

and this script turns every such Service in the current kube context into an
upstream at router deploy time. Undeploy deletes the Service (or the namespace),
and the next router deploy drops the entry.

Only stdlib — the runner container has no pyyaml. Entries are emitted with
JSON-quoted scalars, which YAML 1.2 accepts verbatim.

Usage:
    gen-serving-upstreams.py >> config.yaml

Exit status is 0 when no serving Services exist (nothing is emitted); a kubectl
failure is fatal, since it would silently drop every serving backend.
"""

import json
import subprocess
import sys

LABEL = "miramar.ai/router=true"
ENTRY = """- litellm_params:
    api_base: {api_base}
    api_key: none
    model: {model}
  model_name: {model_name}
"""


def main() -> int:
    raw = subprocess.run(
        ["kubectl", "get", "services", "--all-namespaces", "-l", LABEL, "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    out = []
    names = []
    for svc in json.loads(raw).get("items", []):
        meta = svc["metadata"]
        ann = meta.get("annotations") or {}
        where = f"{meta['namespace']}/{meta['name']}"
        try:
            name = ann["miramar.ai/router-model"]
            model = ann["miramar.ai/router-litellm-model"]
            api_base = ann["miramar.ai/router-api-base"]
        except KeyError as exc:
            print(f"WARNING: {where} is labelled {LABEL} but missing annotation {exc} — skipped", file=sys.stderr)
            continue
        out.append(
            ENTRY.format(
                api_base=json.dumps(api_base),
                model=json.dumps(model),
                model_name=json.dumps(name),
            ).rstrip("\n")
        )
        names.append(f"{name} ({where})")

    if not out:
        print("No serving Services labelled for the router.", file=sys.stderr)
        return 0
    print("# --- serving projects, generated from labelled Services — do not hand-edit ---")
    print("\n".join(out))
    print(f"Generated {len(out)} serving upstream(s): {', '.join(names)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
