"""Unit tests for evallib/scoring.py — the composite math + ranking."""

import pytest

from evallib import scoring


def _row(model, mode, task, *, case_id="c", gate_pass=True, judge=5,
         provenance="real", error=None):
    return {
        "model": model, "mode": mode, "task": task, "case_id": case_id,
        "provenance": provenance, "gate_pass": gate_pass,
        "gates": {"g": gate_pass}, "judge_score": judge, "error": error,
    }


def test_normalize_weights_sums_to_one():
    w = scoring.normalize_weights({"gate_pass": 3, "judge": 1})
    assert w == pytest.approx({"gate_pass": 0.75, "judge": 0.25})


def test_normalize_weights_empty_falls_back_to_equal_split():
    w = scoring.normalize_weights({})
    assert w == pytest.approx({"gate_pass": 0.5, "judge": 0.5})


def test_normalize_weights_all_zero_falls_back():
    assert scoring.normalize_weights({"gate_pass": 0, "judge": 0}) == pytest.approx(
        {"gate_pass": 0.5, "judge": 0.5}
    )


@pytest.mark.parametrize("score,unit", [(1, 0.0), (3, 0.5), (5, 1.0)])
def test_unit_from_1to5(score, unit):
    assert scoring.unit_from_1to5(score) == pytest.approx(unit)


def test_unit_from_1to5_rejects_out_of_range():
    with pytest.raises(ValueError):
        scoring.unit_from_1to5(6)


def test_aggregate_task_counts_and_rates():
    rows = [
        _row("m", "ollama", "t", case_id="1", gate_pass=True, judge=5),
        _row("m", "ollama", "t", case_id="2", gate_pass=False, judge=3),
        _row("m", "ollama", "t", case_id="3", gate_pass=True, judge=None,
             provenance="synthetic"),
        _row("m", "ollama", "t", case_id="4", gate_pass=False, judge=None,
             error="timeout"),
    ]
    agg = scoring.aggregate_task(rows)
    assert agg["n_cases"] == 4
    assert agg["n_real"] == 3
    assert agg["n_synthetic"] == 1
    assert agg["n_error"] == 1
    assert agg["gate_pass_rate"] == pytest.approx(0.5)
    # judged scores: 5 -> 1.0, 3 -> 0.5  => mean 0.75
    assert agg["judge_mean_unit"] == pytest.approx(0.75)
    assert agg["judge_n"] == 2


def test_task_score_weighted_blend():
    agg = {"gate_pass_rate": 1.0, "judge_mean_unit": 0.0}
    # 0.6 * 1.0 + 0.4 * 0.0 = 0.6
    assert scoring.task_score(agg, {"gate_pass": 0.6, "judge": 0.4}) == pytest.approx(0.6)


def test_task_score_no_judge_signal_uses_gates_only():
    agg = {"gate_pass_rate": 0.8, "judge_mean_unit": None}
    assert scoring.task_score(agg, {"gate_pass": 0.6, "judge": 0.4}) == pytest.approx(0.8)


def test_score_matrix_ranks_models_by_composite():
    cfg = {
        "tasks": ["t1", "t2"],
        "score_weights": {
            "t1": {"gate_pass": 0.5, "judge": 0.5},
            "t2": {"gate_pass": 0.5, "judge": 0.5},
        },
    }
    rows = []
    # good model: all gates pass, judge 5
    rows += [_row("good", "ollama", "t1", judge=5), _row("good", "ollama", "t2", judge=5)]
    # bad model: gates fail, judge 1
    rows += [
        _row("bad", "ollama", "t1", gate_pass=False, judge=1),
        _row("bad", "ollama", "t2", gate_pass=False, judge=1),
    ]
    board = scoring.score_matrix(rows, cfg)
    assert [e["model"] for e in board] == ["good", "bad"]
    assert board[0]["composite"] == pytest.approx(1.0)
    assert board[1]["composite"] == pytest.approx(0.0)
    assert board[0]["tasks"]["t1"]["score"] == pytest.approx(1.0)


def test_score_matrix_separates_serving_modes():
    cfg = {"tasks": ["t1"], "score_weights": {"t1": {"gate_pass": 1.0, "judge": 0.0}}}
    rows = [
        _row("m", "ollama", "t1", gate_pass=True),
        _row("m", "guided", "t1", gate_pass=False),
    ]
    board = scoring.score_matrix(rows, cfg)
    assert {(e["model"], e["mode"]) for e in board} == {("m", "ollama"), ("m", "guided")}
    top = board[0]
    assert (top["model"], top["mode"]) == ("m", "ollama")


def test_score_matrix_skips_tasks_with_no_rows():
    cfg = {"tasks": ["t1", "t2"], "score_weights": {}}
    rows = [_row("m", "ollama", "t1", judge=4)]
    board = scoring.score_matrix(rows, cfg)
    assert list(board[0]["tasks"]) == ["t1"]


def test_leaderboard_markdown_shape():
    board = [
        {"model": "a", "mode": "ollama", "composite": 0.812, "n_cases": 10, "n_error": 0},
        {"model": "b", "mode": "guided", "composite": 0.5, "n_cases": 10, "n_error": 2},
    ]
    md = scoring.leaderboard_markdown(board)
    assert "| 1 | `a` | ollama | 0.812 | 10 | 0 |" in md
    assert "| 2 | `b` | guided | 0.500 | 10 | 2 |" in md
    assert md.count("\n") == 4  # 2 header + 2 rows, each newline-terminated
