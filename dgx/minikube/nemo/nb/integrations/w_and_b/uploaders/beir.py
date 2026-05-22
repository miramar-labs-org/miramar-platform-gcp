import json
import os

import wandb
from uploaders.utils import wandb_uploader

BAD_CHARS = [";", ":", "!", "*", " ", ","]


def upload_beir(subdir: str, file: str, experiment_name: str):
    """
    Reads a file at the provided directory path,
    parses the results data and uploads the metrics to wandb
    for the beir evaluation

    Parameters:
    subdir (str): The subdirectory of the results
    file (str): The file to open
    """
    file_name = os.path.join(subdir, file)
    run_name = file
    with open(file_name, "r") as f:
        data = json.load(f)

        def upload_results_metrics():
            for metric, score in data.items():
                if isinstance(score, (float, int)):
                    metric_to_log = metric
                    metric_to_log = "".join(
                        i for i in metric_to_log if not i in BAD_CHARS
                    )
                    wandb.log({metric_to_log: score})

        wandb_uploader(run_name, file_name, upload_results_metrics, experiment_name)
