import os
from io import StringIO

import mlflow
import pandas
from uploaders.utils import mlflow_uploader

BAD_CHARS = [";", ":", "!", "*", " ", ","]


def upload_mt_bench(subdir: str, file: str):
    """
    Reads a file at the provided directory path,
    parses the results data and uploads the metrics to mlflow
    for the mtbench evaluation

    Parameters:
    subdir (str): The subdirectory of the results
    file (str): The file to open
    """
    file_name = os.path.join(subdir, file)
    run_name = "mtbench_" + file

    with open(file_name, "r") as fp:

        def upload_results_metrics():
            lines = fp.readlines()
            total_idx = next((i for i, line in enumerate(lines) if "total" in line), 0)
            lines = lines[total_idx:]

            # Parse the remaining lines as a CSV
            mt_df = pandas.read_csv(StringIO("\n".join(lines)), header=None)

            for row_index, (metric, result) in mt_df.iterrows():
                if isinstance(result, (float, int)):
                    metric_to_log = metric
                    metric_to_log = "".join(
                        i for i in metric_to_log if not i in BAD_CHARS
                    )

                    mlflow.log_metric(metric_to_log, result)

        mlflow_uploader(run_name, file_name, upload_results_metrics)
