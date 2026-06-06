# Project-supplied dataset formatters.
#
# Each function signature: (example: dict) -> {"instruction": str, "response": str, "source": str}
# Add one function per dataset listed in config.yaml, then register it in FORMATTERS below.
#
# The Build cell inlines this entire file into the prepare_dataset KFP component body.
# Any imports used here must be available inside the component container — add them
# to prepare_dataset's packages_to_install if they are not already there.


def format_example(example):
    # TODO: replace with your dataset-specific formatter.
    # `example` is a single row dict from the HuggingFace dataset.
    instruction = example.get("question", "")
    response = example.get("answer", "")
    return {
        "instruction": instruction,
        "response": response,
        "source": "example-dataset",
    }


# Map config.yaml dataset names → formatter functions.
# Each key must match a `name:` entry in config.yaml datasets.
FORMATTERS = {
    "example-dataset": format_example,
}
