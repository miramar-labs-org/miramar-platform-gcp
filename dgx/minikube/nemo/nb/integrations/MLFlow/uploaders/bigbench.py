import json
import os

import mlflow
from uploaders.utils import mlflow_uploader

BAD_CHARS = [";", ":", "!", "*", " ", ","]


def upload_bigbench(subdir: str, file: str):
    """
    Reads a file at the provided directory path,
    parses the results data and uploads the metrics to mlflow
    for the bigbench evaluation

    Parameters:
    subdir (str): The subdirectory of the results
    file (str): The file to open
    """
    file_name = os.path.join(subdir, file)
    run_name = "bigbench_" + file
    with open(file_name, "r") as f:
        data = json.load(f)[0]

        def upload_results_metrics():
            for score in data["scores"]:
                metric, score, num_shots = (
                    score["metric"],
                    score["score"],
                    score["num_shots"],
                )
                if isinstance(score, (float, int)):
                    metric_to_log = metric
                    metric_to_log = "".join(
                        i for i in metric_to_log if not i in BAD_CHARS
                    )
                    mlflow.log_metric(metric_to_log, score, num_shots)

        mlflow_uploader(run_name, file_name, upload_results_metrics)
