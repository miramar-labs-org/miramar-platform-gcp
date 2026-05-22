import json
import os

import mlflow
from uploaders.utils import mlflow_uploader

BAD_CHARS = [";", ":", "!", "*", " ", ","]


def upload_custom(subdir: str, file: str):
    """
    Reads a file at the provided directory path,
    parses the results data and uploads the metrics to mlflow
    for the custom evaluation

    Parameters:
    subdir (str): The subdirectory of the results
    file (str): The file to open
    """
    file_name = os.path.join(subdir, file)
    run_name = "custom_eval_" + file
    with open(file_name, "r") as f:
        data = json.load(f)

        def upload_results_metrics():
            for llm_name, scorer_types in data.items():
                for scorer_type, metrics in scorer_types.items():
                    for metric_index, (metric, result) in enumerate(metrics.items()):
                        if isinstance(result, (float, int)):
                            metric_to_log = metric
                            metric_to_log = "".join(
                                i for i in metric_to_log if not i in BAD_CHARS
                            )
                            mlflow.log_metric(metric_to_log, result)

        mlflow_uploader(run_name, file_name, upload_results_metrics)
