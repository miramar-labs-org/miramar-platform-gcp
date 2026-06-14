# Eval helper functions — inlined into baseline_eval and post_finetune_eval
# by scripts/build_pipeline.py at the # <<< EVAL_HELPERS_INJECT >>> marker.
# Customize extract_answer and _make_user_content for your dataset.
# Do not add imports here that aren't available in the component container.

import re as _re


def extract_answer(text):
    # TODO: implement for your dataset's answer format.
    # For multiple-choice: return the letter (a/b/c/d).
    # For yes/no: return 'yes' or 'no'.
    return text.strip().lower().split()[0] if text.strip() else ""


def make_infer_fn(tokenizer, model, system_message, max_new_tokens, do_sample):
    # TODO: implement for your model's chat template and generation config.
    def _infer(row):
        return ""  # TODO: apply chat template, generate, decode
    return _infer


def _make_user_content(row):
    # TODO: format the user-turn content for inference.
    # row has keys: instruction, response, source
    return row["instruction"]
