"""Pure, importable helpers for the kfp-eval pipeline.

Everything in this package is stdlib-only and side-effect-free so it can be
both unit-tested with pytest AND spliced verbatim into a KFP component body by
`scripts/build_pipeline.py` via a `# inline: evallib/<module>.py` directive.
"""
