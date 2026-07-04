"""
utils.py — shared helpers injected into eval pipeline components.

Injected into: baseline_eval, post_finetune_eval (via UTILS_INJECT marker in notebook cells)

All functions must be importable with no external state — each KFP component is an
isolated container; this file is inlined into the function body by build_pipeline.py.
"""


def compute_auc(labels, probs_positive):
    """Compute AUC-ROC for binary classification.

    Args:
        labels:         list of int ground-truth labels (0 or 1)
        probs_positive: list of float — predicted probability of the positive class (label=1)

    Returns:
        float AUC-ROC in [0, 1]. Returns 0.5 when labels contain only one class
        (e.g. the baseline eval on a small imbalanced sample).
    """
    from sklearn.metrics import roc_auc_score
    try:
        if len(set(labels)) < 2:
            print("[compute_auc] Only one class present — returning 0.5")
            return 0.5
        return float(roc_auc_score(labels, probs_positive))
    except Exception as exc:
        print(f"[compute_auc] Error: {exc} — returning 0.5")
        return 0.5
