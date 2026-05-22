import argparse
import os
import sys
import json

import mlflow
from dotenv import load_dotenv
from uploaders.beir import upload_beir
from uploaders.bigbench import upload_bigbench
from uploaders.bigcode_latest import upload_bigcode_latest
from uploaders.custom import upload_custom
from uploaders.lm_harness import upload_lm_harness
from uploaders.mt_bench import upload_mt_bench
from uploaders.multilingual import upload_multilingual
from uploaders.utils import (
    clean_up,
    download_results_zip,
    find_results_folder,
    unzip_file,
)
from uploaders.similarity_metrics import upload_similarity_metrics
import urllib3

def main(results_abs_dir, evaluation_id, mlflow_uri, experiment_name):
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    rootdir = results_abs_dir
    if isinstance(evaluation_id, str):
        # if evaluation_id is defined, query eval ms api to download results & unzip
        # if results not found, evaluation is unsuccessful status and must exit
        output_file_name = "downloaded_results.zip"
        download_results_zip(evaluation_id, output_file_name)
        unzip_file(
            os.path.dirname(os.path.abspath(__file__)) + "/downloaded_results.zip"
        )
        results_path = find_results_folder()
        rootdir = results_path

    mlflow.set_tracking_uri(uri=mlflow_uri)
    mlflow.set_experiment(experiment_name)

    try:
        # main logic
        for subdir, dirs, files in os.walk(rootdir):
            for file in files:
                args = [subdir, file]
                if file == "results.json":
                    # Try to detect if this is a similarity metrics result
                    try:
                        with open(f"{subdir}/{file}", "r") as f:
                            content = json.load(f)
                            if "tasks" in content and any("metrics" in task_data for task_data in content["tasks"].values()):
                                upload_similarity_metrics(subdir, file, experiment_name)
                                continue
                    except json.JSONDecodeError:
                        pass  # Not a valid JSON file, try other uploaders
                if "beir" in subdir and file.startswith("beir.json"):
                    upload_beir(*args)
                elif "multilingual" in subdir and file.startswith("aggregate_scores"):
                    upload_multilingual(*args)
                elif "bigcode_latest" in subdir and file.startswith(
                    "bigcode-aggregate_scores"
                ):
                    upload_bigcode_latest(*args)
                elif "bigbench" in subdir and file.startswith("aggregate_scores"):
                    upload_bigbench(*args)
                # llm-as-a-judge mtbench
                elif "mtbench" in subdir and file.endswith("csv"):
                    upload_mt_bench(*args)
                # custom eval
                elif "custom_eval" in subdir and file.startswith("aggregate_scores"):
                    upload_custom(*args)
                # lm-harness
                elif file.startswith("lm-harness"):
                    upload_lm_harness(*args)

        if isinstance(evaluation_id, str):
            # make sure if evaluation_id was provided, that cleanup of the pulled results is completed
            clean_up("./downloaded_results.zip", "./downloaded_results")
    except Exception as e:
        print(f"An unexpected error happened: {e}")
        if isinstance(evaluation_id, str):
            # make sure if evaluation_id was provided, that cleanup of the pulled results is completed
            clean_up("./downloaded_results.zip", "./downloaded_results")


if __name__ == "__main__":
    # Create the parser
    parser = argparse.ArgumentParser(
        description="A script that consumes an evaluation results provided directory, provided an mlflow uri and uploads results"
    )

    # Add arguments
    parser.add_argument(
        "--results_abs_dir",
        type=str,
        required=False,
        help="Absolute path to results file location",
    )
    parser.add_argument(
        "--evaluation_id",
        type=str,
        required=False,
        help="Evaluation ID for results to be drawn from (must be successful evaluation)",
    )
    parser.add_argument("--mlflow_uri", type=str, required=False, help="MLFlow URI")
    parser.add_argument(
        "--experiment_name", type=str, required=False, help="MLFlow Experiment Name"
    )

    # Parse the arguments
    args = parser.parse_args()

    # Load environment variables from .env file
    load_dotenv()

    # Access the variables
    mlflow_uri_env = os.getenv("MLFLOW_URI")
    experiment_name = os.getenv("EXPERIMENT_NAME")

    # Check if at least one variable is provided
    if args.results_abs_dir is None and args.evaluation_id is None:
        print(
            "Error: At least one of --results_abs_dir or --evaluation_id must be provided."
        )
        sys.exit(1)  # Exit with an error code

    # Must either provide the MLFlow URI in a .env or as an argument
    if mlflow_uri_env is None and args.mlflow_uri is None:
        print(
            "Error: At least one of --mlflow_uri_env or --mlflow_uri must be provided."
        )
        sys.exit(1)  # Exit with an error code

    # Call the main function with the parsed arguments
    main(
        args.results_abs_dir,
        args.evaluation_id,
        mlflow_uri_env or args.mlflow_uri,
        experiment_name or args.experiment_name or "Nemo Evaluator MS Testing",
    )
