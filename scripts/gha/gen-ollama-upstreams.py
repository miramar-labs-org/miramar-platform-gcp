#!/usr/bin/env python3
"""Generate LiteLLM upstream entries for every Ollama model cached on a host.

Ollama runs host-native (systemd) on both the DGX Spark and the AGX Orin — it is
not a k3s workload on either — so there is no in-cluster Service and no CoreDNS
record for it. Both are reached by host IP ({MACHINE}_HOST_IP) on Ollama's
OpenAI-compatible /v1 endpoint.

Each host's catalog is dynamic (`ollama pull` and the model exists), so a
hand-maintained block in litellm-config.yaml drifts: the committed AGX block
listed 6 of the 7 cached models and had no mechanism to notice. The entries are
generated at deploy time instead.

Emitted model_names carry a host prefix (`dgx/`, `agx/`) so the two hosts stay
distinct — both carry qwen3.6:35b-a3b, gpt-oss:20b, nemotron-3-nano:30b and
phi4, and without the prefix a client could not choose the host, so work meant
for the DGX could land on the AGX's 40 GB budget.

Only stdlib — the runner container has no pyyaml. Entries are emitted with
JSON-quoted scalars, which YAML 1.2 accepts verbatim.

Usage:
    gen-ollama-upstreams.py --host-ip 192.168.1.200 --prefix dgx/ >> config.yaml
    gen-ollama-upstreams.py --host-ip 192.168.1.202 --prefix agx/ >> config.yaml

Exit status is 0 even when the host is unreachable (the AGX in particular is
allowed to be powered off); in that case nothing is emitted and a warning goes
to stderr.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

ENTRY = """- litellm_params:
    api_base: {api_base}
    api_key: none
    model: {model}
  model_name: {model_name}
"""


def fetch_models(host_ip: str, port: int, timeout: float) -> list[str]:
    url = f"http://{host_ip}:{port}/api/tags"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        payload = json.load(resp)
    return sorted(m["name"] for m in payload.get("models", []))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host-ip", required=True, help="host IP ({MACHINE}_HOST_IP)")
    ap.add_argument("--prefix", required=True, help="model_name prefix, e.g. dgx/ or agx/")
    ap.add_argument("--port", type=int, default=11434)
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    label = args.prefix.rstrip("/") or args.host_ip

    try:
        models = fetch_models(args.host_ip, args.port, args.timeout)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
        print(
            f"WARNING: {label} Ollama at {args.host_ip}:{args.port} is unreachable ({exc}). "
            f"No {args.prefix} upstreams generated — the router will serve its other backends only.",
            file=sys.stderr,
        )
        return 0

    if not models:
        print(
            f"WARNING: {label} Ollama at {args.host_ip}:{args.port} has no models cached.",
            file=sys.stderr,
        )
        return 0

    api_base = json.dumps(f"http://{args.host_ip}:{args.port}/v1")
    out = [
        f"# --- {args.prefix} generated from {args.host_ip}:{args.port}/api/tags — do not hand-edit ---"
    ]
    for name in models:
        out.append(
            ENTRY.format(
                api_base=api_base,
                model=json.dumps(f"openai/{name}"),
                model_name=json.dumps(f"{args.prefix}{name}"),
            ).rstrip("\n")
        )
    print("\n".join(out))
    print(
        f"Generated {len(models)} {args.prefix} upstream(s): {', '.join(models)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
