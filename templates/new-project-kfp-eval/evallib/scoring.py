"""Deterministic scoring + ranking for the model bakeoff.

Input is a flat list of per-case result rows (one dict per case, per
(model, serving_mode, task)):

    {
      "model": str,            # candidate id from config.yaml models[].id
      "mode": str,             # serving mode: "ollama" | "guided"
      "task": str,             # harness name
      "case_id": str,
      "provenance": "real" | "synthetic",
      "gate_pass": bool,       # True iff every gate for this case passed
      "gates": {name: bool},   # individual gate outcomes (informational)
      "judge_score": int|None, # 1-5 from the LLM judge, or None if not judged / unparseable
      "error": str|None,       # non-None if run_case raised / timed out
    }

Output is a leaderboard: one entry per (model, mode), ranked by weighted
composite descending.

stdlib-only — safe to `# inline: evallib/scoring.py` into a component body.
"""

from collections import defaultdict

_METRICS = ("gate_pass", "judge")


def normalize_weights(weights: dict) -> dict:
    """Scale a {metric: weight} dict so the values sum to 1.0.

    Empty / all-zero input falls back to an equal split across the known metrics.
    """
    weights = {k: float(v) for k, v in (weights or {}).items() if float(v) > 0}
    total = sum(weights.values())
    if total <= 0:
        return {m: 1.0 / len(_METRICS) for m in _METRICS}
    return {k: v / total for k, v in weights.items()}


def unit_from_1to5(score) -> float:
    """Map a 1-5 judge score onto 0.0-1.0. Raises on out-of-range."""
    s = float(score)
    if s < 1.0 or s > 5.0:
        raise ValueError(f"judge score {score} outside 1-5")
    return (s - 1.0) / 4.0


def aggregate_task(rows: list) -> dict:
    """Collapse all rows for a single (model, mode, task) into summary metrics."""
    n = len(rows)
    n_real = sum(1 for r in rows if r.get("provenance") != "synthetic")
    n_error = sum(1 for r in rows if r.get("error"))
    n_gate_pass = sum(1 for r in rows if r.get("gate_pass"))

    judged = [r["judge_score"] for r in rows if r.get("judge_score") is not None]
    judge_mean_unit = (
        sum(unit_from_1to5(s) for s in judged) / len(judged) if judged else None
    )

    return {
        "n_cases": n,
        "n_real": n_real,
        "n_synthetic": n - n_real,
        "n_error": n_error,
        "gate_pass_rate": (n_gate_pass / n) if n else 0.0,
        "judge_mean_unit": judge_mean_unit,
        "judge_n": len(judged),
    }


def task_score(agg: dict, weights: dict) -> float:
    """Weighted metric score for one task, in 0.0-1.0.

    A task with no judged cases redistributes the judge weight onto gate_pass.
    """
    w = normalize_weights(weights)
    values = {
        "gate_pass": agg.get("gate_pass_rate", 0.0),
        "judge": agg.get("judge_mean_unit"),
    }
    if values["judge"] is None:
        # No judge signal — score on gates alone.
        return values["gate_pass"]
    return sum(w.get(m, 0.0) * values[m] for m in _METRICS)


def score_matrix(rows: list, cfg: dict) -> list:
    """Build the ranked leaderboard from all result rows.

    Returns a list of dicts sorted by `composite` descending:
        {
          "model", "mode", "composite",
          "n_cases", "n_error",
          "tasks": {task: {**aggregate_task(...), "score": float}},
        }
    """
    tasks = list(cfg.get("tasks") or [])
    weights_cfg = cfg.get("score_weights") or {}

    by_cell = defaultdict(list)
    for r in rows:
        by_cell[(r["model"], r["mode"])].append(r)

    leaderboard = []
    for (model, mode), cell_rows in by_cell.items():
        by_task = defaultdict(list)
        for r in cell_rows:
            by_task[r["task"]].append(r)

        task_block = {}
        per_task_scores = []
        # Score every task named in config that has rows; skip silently otherwise.
        for task in tasks or sorted(by_task):
            if task not in by_task:
                continue
            agg = aggregate_task(by_task[task])
            score = task_score(agg, weights_cfg.get(task, {}))
            task_block[task] = {**agg, "score": score}
            per_task_scores.append(score)

        composite = (
            sum(per_task_scores) / len(per_task_scores) if per_task_scores else 0.0
        )
        leaderboard.append(
            {
                "model": model,
                "mode": mode,
                "composite": composite,
                "n_cases": len(cell_rows),
                "n_error": sum(1 for r in cell_rows if r.get("error")),
                "tasks": task_block,
            }
        )

    leaderboard.sort(key=lambda e: e["composite"], reverse=True)
    return leaderboard


def leaderboard_markdown(leaderboard: list) -> str:
    """Render the leaderboard as a Markdown table (for the MLflow artifact + RUNS.md)."""
    lines = [
        "| Rank | Model | Mode | Composite | Cases | Errors |",
        "| ---- | ----- | ---- | --------- | ----- | ------ |",
    ]
    for i, e in enumerate(leaderboard, 1):
        lines.append(
            f"| {i} | `{e['model']}` | {e['mode']} | {e['composite']:.3f} "
            f"| {e['n_cases']} | {e['n_error']} |"
        )
    return "\n".join(lines) + "\n"
