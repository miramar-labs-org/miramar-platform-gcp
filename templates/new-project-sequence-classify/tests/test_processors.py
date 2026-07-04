"""Smoke tests for processors.py — run before deploying."""

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).parent.parent
PROC_PATH = ROOT / "processors.py"


def _load_processors():
    spec = importlib.util.spec_from_file_location("processors", PROC_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_processors_dict_exists():
    mod = _load_processors()
    assert hasattr(mod, "PROCESSORS"), "processors.py must define PROCESSORS dict"
    assert isinstance(mod.PROCESSORS, dict)
    assert len(mod.PROCESSORS) > 0, "PROCESSORS dict must not be empty"


def test_loaders_dict_exists():
    mod = _load_processors()
    assert hasattr(mod, "LOADERS"), "processors.py must define LOADERS dict"
    assert isinstance(mod.LOADERS, dict)
    assert len(mod.LOADERS) > 0, "LOADERS dict must not be empty"


def test_keys_match():
    mod = _load_processors()
    for key in mod.PROCESSORS:
        assert key in mod.LOADERS, f"PROCESSORS key '{key}' has no matching LOADERS entry"
    for key in mod.LOADERS:
        assert key in mod.PROCESSORS, f"LOADERS key '{key}' has no matching PROCESSORS entry"


def test_processor_output_schema():
    mod = _load_processors()
    for name, fn in mod.PROCESSORS.items():
        # Build a minimal synthetic row and pass it through the processor
        synthetic = {
            "sequence": "ATCGATCGATCG",
            "label": 1,
            "chrom": "chr1",
            # common alternative field names
            "chromosome": "chr1",
            "seq": "ATCGATCGATCG",
        }
        try:
            row = fn(synthetic)
        except Exception as exc:
            raise AssertionError(f"Processor '{name}' raised {exc!r} on synthetic row") from exc
        assert "sequence" in row, f"Processor '{name}' output missing 'sequence' field"
        assert "label" in row, f"Processor '{name}' output missing 'label' field"
        assert "source" in row, f"Processor '{name}' output missing 'source' field"
        assert isinstance(row["sequence"], str), f"Processor '{name}': 'sequence' must be str"
        assert isinstance(row["label"], int), f"Processor '{name}': 'label' must be int"


def test_utils_compute_auc():
    """compute_auc returns sensible values."""
    sys.path.insert(0, str(ROOT))
    from utils import compute_auc

    # Single class — should return 0.5 without error
    assert compute_auc([0, 0, 0], [0.1, 0.2, 0.3]) == 0.5

    # Perfect separation
    auc = compute_auc([0, 1], [0.0, 1.0])
    assert abs(auc - 1.0) < 1e-6

    # Random prediction
    auc = compute_auc([0, 0, 1, 1], [0.5, 0.5, 0.5, 0.5])
    assert abs(auc - 0.5) < 0.01
