#!/usr/bin/env python3
"""Generate LiteLLM upstream entries for every Ollama model cached on the AGX Orin.

The AGX is a host-native Ollama runner with no k3s, so there is no in-cluster
Service and no CoreDNS record — it is reached by host IP (AGX_HOST_IP) on the
OpenAI-compatible /v1 endpoint. Its catalog is dynamic (`ollama pull` and the
model exists), so hand-maintaining the list in litellm-config.yaml guarantees
drift: the committed block listed 6 of the 7 cached models and had no mechanism
to notice.

Emitted entries are prefixed `agx/` so they stay distinct from the identically
named models on the DGX (both hosts carry qwen3.6:35b-a3b, gpt-oss:20b,
nemotron-3-nano:30b and phi4). Without the prefix a client could not choose the
host, and work meant for the DGX could land on the AGX's 40 GB budget.

Only stdlib — the runner container has no pyyaml. Entries are emitted with
JSON-quoted scalars, which YAML 1.2 accepts verbatim.

Usage:
    gen-agx-upstreams.py --host-ip 192.168.1.202 >> config.yaml

Exit status is 0 even when the AGX is unreachable (it is allowed to be powered
off); in that case nothing is emitted and a warning goes to stderr.
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
    ap.add_argument("--host-ip", required=True, help="AGX host IP (AGX_HOST_IP)")
    ap.add_argument("--port", type=int, default=11434)
    ap.add_argument("--prefix", default="agx/", help="model_name prefix (default: agx/)")
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    try:
        models = fetch_models(args.host_ip, args.port, args.timeout)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
        print(
            f"WARNING: AGX Ollama at {args.host_ip}:{args.port} is unreachable ({exc}). "
            "No agx/ upstreams generated — the router will serve its other backends only.",
            file=sys.stderr,
        )
        return 0

    if not models:
        print(
            f"WARNING: AGX Ollama at {args.host_ip}:{args.port} has no models cached.",
            file=sys.stderr,
        )
        return 0

    api_base = json.dumps(f"http://{args.host_ip}:{args.port}/v1")
    out = [f"# --- generated from {args.host_ip}:{args.port}/api/tags — do not hand-edit ---"]
    for name in models:
        out.append(
            ENTRY.format(
                api_base=api_base,
                model=json.dumps(f"openai/{name}"),
                model_name=json.dumps(f"{args.prefix}{name}"),
            ).rstrip("\n")
        )
    print("\n".join(out))
    print(f"Generated {len(models)} agx/ upstream(s): {', '.join(models)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
