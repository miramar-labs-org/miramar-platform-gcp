import json
import os
import re

import mlflow
from uploaders.utils import mlflow_uploader

BAD_CHARS = [";", ":", "!", "*", " ", ","]


def upload_bigcode_latest(subdir: str, file: str):
    """
    Reads a file at the provided directory path,
    parses the results data and uploads the metrics to mlflow
    for the bigcode evaluation

    Parameters:
    subdir (str): The subdirectory of the results
    file (str): The file to open
    """
    file_name = os.path.join(subdir, file)
    run_name = "bigcode_latest_" + file
    with open(file_name, "r") as f:
        data = json.load(f)

        def upload_results_metrics():
            for taskConfig in data:
                for task_name, taskItems in taskConfig.items():
                    if task_name == "config":
                        continue
                    for metric_index, field in enumerate(taskItems.items()):
                        (metric, result) = field
                        if isinstance(result, (float, int)):
                            metric_to_log = re.sub(r"@", "_at_", metric)
                            metric_to_log = "".join(
                                i for i in metric_to_log if not i in BAD_CHARS
                            )
                            mlflow.log_metric(metric_to_log, result)

        mlflow_uploader(run_name, file_name, upload_results_metrics)
