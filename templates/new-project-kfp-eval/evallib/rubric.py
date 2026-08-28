"""Fixed LLM-as-judge rubric wrapper + response parser.

A harness supplies a task-specific `judge_prompt(case, result)` string (or None
to skip judging). This module wraps it in a constant rubric so every task is
scored on the same 1-5 scale and the output is always parseable JSON.

stdlib-only — safe to `# inline: evallib/rubric.py` into a component body.
"""

import json
import re

RUBRIC_SYSTEM = (
    "You are a strict evaluation judge. You will be given a task description and "
    "a candidate model's output. Score the output on a 1-5 integer scale:\n"
    "  1 = unusable / wrong / off-task\n"
    "  2 = major flaws\n"
    "  3 = acceptable with notable gaps\n"
    "  4 = good, minor issues\n"
    "  5 = excellent, no material issues\n"
    "Respond with a single JSON object and nothing else: "
    '{"score": <1-5>, "justification": "<one sentence>"}'
)


def wrap_judge_prompt(task_prompt: str) -> list:
    """Return an OpenAI-style messages list for the judge call."""
    return [
        {"role": "system", "content": RUBRIC_SYSTEM},
        {"role": "user", "content": task_prompt},
    ]


def parse_judge_response(text: str) -> dict:
    """Best-effort parse of a judge reply into {"score": int|None, "justification": str}.

    Tolerates code fences, leading prose, and a trailing explanation. Returns
    score=None when no valid 1-5 integer can be recovered — the caller decides
    whether to retry or record the miss.
    """
    if not text or not text.strip():
        return {"score": None, "justification": ""}

    obj = None
    # Try the whole string, then the first {...} block.
    candidates = [text]
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if m:
        candidates.append(m.group(0))
    for cand in candidates:
        try:
            parsed = json.loads(cand)
            if isinstance(parsed, dict):
                obj = parsed
                break
        except (ValueError, TypeError):
            continue

    if obj is None:
        # Last resort: a bare "score: 4" style mention.
        m = re.search(r"score\D{0,4}([1-5])", text, re.IGNORECASE)
        if m:
            return {"score": int(m.group(1)), "justification": text.strip()[:280]}
        return {"score": None, "justification": text.strip()[:280]}

    raw = obj.get("score")
    score = None
    try:
        if raw is not None:
            score = int(round(float(raw)))
            if score < 1 or score > 5:
                score = None
    except (ValueError, TypeError):
        score = None

    justification = str(obj.get("justification", "")).strip()
    return {"score": score, "justification": justification}
