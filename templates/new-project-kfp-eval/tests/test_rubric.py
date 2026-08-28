"""Unit tests for evallib/rubric.py — judge prompt wrapper + response parsing."""

from evallib import rubric


def test_wrap_judge_prompt_shape():
    msgs = rubric.wrap_judge_prompt("Was the answer grounded?")
    assert [m["role"] for m in msgs] == ["system", "user"]
    assert msgs[0]["content"] == rubric.RUBRIC_SYSTEM
    assert msgs[1]["content"] == "Was the answer grounded?"


def test_parse_clean_json():
    out = rubric.parse_judge_response('{"score": 4, "justification": "solid"}')
    assert out == {"score": 4, "justification": "solid"}


def test_parse_json_in_code_fence():
    text = 'Here you go:\n```json\n{"score": 5, "justification": "great"}\n```'
    assert rubric.parse_judge_response(text)["score"] == 5


def test_parse_json_with_trailing_prose():
    text = '{"score": 2, "justification": "weak"}\n\nLet me know if you need more.'
    out = rubric.parse_judge_response(text)
    assert out["score"] == 2
    assert out["justification"] == "weak"


def test_parse_float_score_rounds_to_int():
    assert rubric.parse_judge_response('{"score": 3.0}')["score"] == 3


def test_parse_out_of_range_score_is_none():
    assert rubric.parse_judge_response('{"score": 9}')["score"] is None


def test_parse_bare_score_mention():
    assert rubric.parse_judge_response("I would rate this a score of 4 overall.")["score"] == 4


def test_parse_empty_string():
    assert rubric.parse_judge_response("")["score"] is None


def test_parse_garbage():
    assert rubric.parse_judge_response("total nonsense no number here")["score"] is None
