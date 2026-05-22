import json
import os

import wandb
from uploaders.utils import wandb_uploader

BAD_CHARS = [";", ":", "!", "*", " ", ","]


def upload_lm_harness(subdir: str, file: str, experiment_name: str):
    """
    Reads a file at the provided directory path,
    parses the results data and uploads the metrics to wandb
    for the lm harness evaluation

    Parameters:
    subdir (str): The subdirectory of the results
    file (str): The file to open
    """
    file_name = os.path.join(subdir, file)
    run_name = file
    with open(file_name, "r") as f:
        data = json.load(f)

        def upload_results_metrics():
            # Log the nested JSON
            for key, value in data["results"].items():
                for metric, result in value.items():
                    if isinstance(result, (float, int)):
                        metric_to_log = key + "_" + metric
                        metric_to_log = "".join(
                            i for i in metric_to_log if not i in BAD_CHARS
                        )
                        wandb.log({metric_to_log: result})

        wandb_uploader(run_name, file_name, upload_results_metrics, experiment_name)
