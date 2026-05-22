import json
import mlflow
import os

def upload_similarity_metrics(subdir, file, experiment_name=None):
    """
    Upload similarity metrics results to MLflow.
    - Uses experiment_name as run name if provided
    - Uploads the original results.json as an artifact
    """
    with open(f"{subdir}/{file}", "r") as f:
        results = json.load(f)
    
    # Extract evaluation tag from experiment name if it exists
    # Assuming format is "tag_eval-id" or just "eval-id"
    run_name = experiment_name if experiment_name else "Similarity Metrics Evaluation"
    
    # Start a new MLflow run with the specified name
    with mlflow.start_run(run_name=run_name):
        # Upload the original results file as an artifact
        mlflow.log_artifact(f"{subdir}/{file}", "raw_results")
        
        # Extract metrics from the results structure
        if "tasks" in results:
            for task_name, task_data in results["tasks"].items():
                if "metrics" in task_data:
                    metrics = task_data["metrics"]
                    for metric_name, metric_data in metrics.items():
                        if "scores" in metric_data:
                            for score_name, score_data in metric_data["scores"].items():
                                if "value" in score_data:
                                    # Log the metric with a clear name
                                    metric_key = f"{metric_name}_{score_name}"
                                    mlflow.log_metric(metric_key, score_data["value"])
        
        # Log additional metadata
        mlflow.log_params({
            "task_name": task_name,
            "evaluation_type": "similarity_metrics"
        })