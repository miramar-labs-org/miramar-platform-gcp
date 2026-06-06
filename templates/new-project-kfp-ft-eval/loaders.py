# Dataset loaders — one lambda per dataset, registered in LOADERS dict.
# Each value: () -> HuggingFace Dataset (train split, mapped through formatter)
# Key must match a `name:` entry in config.yaml datasets.
LOADERS = {
    "example-dataset": lambda: [],  # TODO: replace with real loader
}
