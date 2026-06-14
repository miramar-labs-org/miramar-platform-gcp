# Dataset loaders — one lambda per dataset, registered in LOADERS dict.
# Each value: () -> HuggingFace Dataset (train split, mapped through formatter)
# Key must match a `name:` entry in config.yaml datasets.
# NOTE: formatter functions are already in scope (inlined before this file by the build step).
# Do NOT add `from formatters import ...` — formatters.py is not a separate module inside the component.
from datasets import load_dataset

LOADERS = {
    "example-dataset": lambda: [],  # TODO: replace with real loader
}
