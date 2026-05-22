# helper to start and stop mlflow and ensure artifacts are always uploaded
import os
import shutil
import zipfile

import mlflow
import requests

from . import logger


def mlflow_uploader(run_name, file_name, upload_results_metrics):
    with mlflow.start_run() as run:
        # Set metadata tags
        mlflow.set_tag("mlflow.runName", run_name)
        upload_results_metrics()
        
        # Log the JSON file as an artifact
        mlflow.log_artifact(file_name)
        # Retrieve the run ID (optional, for reference)
        run_id = run.info.run_id
        logger.info(f"Run ID: {run_id}")
        mlflow.end_run()


# using staging from eval ms...improve script to know where to query from
def download_results_zip(evaluation_id, output_filename):
    try:
        headers = {"accept": "application/json"}

        eval_ms_url = os.getenv(
            "EVAL_MS_URL", "https://evaluation.stg.llm.ngc.nvidia.com/v1"
        )

        # Send a GET request to the API
        response = requests.get(
            eval_ms_url + "/evaluations/" + evaluation_id + "/download-results",
            headers=headers,
        )

        # Check if the request was successful
        if response.status_code == 200:
            # Write the content to a ZIP file
            with open(output_filename, "wb") as f:
                f.write(response.content)
            logger.info(f"ZIP file downloaded successfully: {output_filename}")
        else:
            logger.error(
                f"Failed to download ZIP file. Status code: {response.status_code}"
            )

    except Exception as e:
        logger.error(f"An error occurred when attempting to download the results: {e}")


# unzip the file
def unzip_file(zip_file_path, extract_to="."):
    """Unzip the specified ZIP file into a folder named after the ZIP file."""
    # Create a folder name based on the zip file name
    folder_name = os.path.splitext(os.path.basename(zip_file_path))[0]
    extract_folder = os.path.join(extract_to, folder_name)

    # Create the extraction folder if it doesn't exist
    os.makedirs(extract_folder, exist_ok=True)

    with zipfile.ZipFile(zip_file_path, "r") as zip_ref:
        extract_folder_real = os.path.realpath(extract_folder)
        for member in zip_ref.infolist():
            target = os.path.realpath(os.path.join(extract_folder, member.filename))
            if not target.startswith(extract_folder_real + os.sep) and target != extract_folder_real:
                raise ValueError(f"Zip entry '{member.filename}' would extract outside target directory")
        zip_ref.extractall(extract_folder)

    logger.info(f"Extracted {zip_file_path} to {extract_folder}")


# delete the zip + unzipped file for clean up
def clean_up(zip_file_path=".", extract_to="."):
    """Delete the ZIP file and extracted directory."""
    if os.path.exists(zip_file_path):
        os.remove(zip_file_path)
        logger.info(f"Deleted ZIP file: {zip_file_path}")
    if os.path.exists(extract_to):
        shutil.rmtree(extract_to)
        logger.info(f"Deleted extracted directory: {extract_to}")


# traverse the results for the expected path
def find_results_folder(start_path="."):
    """Traverse the directories to find the 'results' folder."""
    for root, dirs, files in os.walk(start_path):
        if "results" in dirs:
            results_path = os.path.join(root, "results")
            logger.info(f"Found 'results' folder at: {results_path}")
            return results_path  # Return the path of the results folder
    logger.info(f"No 'results' folder found.")
    return None
