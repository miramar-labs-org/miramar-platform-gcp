## MLFlow Integration Script

### Description:

MLFlow Evaluator Ingestion script `mlflow_eval_integration.py` uploads evaluation results to an MLFlow provided uri. The means to provide evaluation results to the script are as follows:

1. An absolute path to the evaluation results directory, obtained by downloading results using Evaluator MS endpoint

#### Installation

To set up the required packages, run the following commands:

create and start up conda

```
conda create --name mlflow python=3.8
```

```
conda activate mlflow
```

install packages once activated

```
pip install -r requirements.txt
```

### Interactions with the script

1. Create a .env file inside the MLFlow directory
   Populate the .env file with:

```
MLFLOW_URI=<MLFLOW_URI>
EXPERIMENT_NAME=<EXPERIMENT_NAME>
```

2. Arguments to the script

-   MLFlow URI: not optional
    1. as an argument to the script `--mlflow_uri "<MLFLOW_URI>"`
    2. via populated .env `MLFLOW_URI=<MLFLOW_URI>`
-   results_abs_dir: optional `--results_abs_dir="<ABSOLUTE_PATH_TO_DOWNLOADED_RESULTS>/bigcode_latest/automatic/bigcode_latest/results/"`
-   experiment_name: optional `--experiment_name="<EXPERIMENT_NAME>"`

The experiment name desired to create in MLFlow is included as an optional variable that can be passed to the script,
the script defaults to "Nemo Evaluator MS Testing" if not provided.

_Note: The results file types that get uploaded are consistent with the files Evaluation MS API parse to shape results responses_

### MLFlow

In MLFlow UI, you should see the naming convention `${evaluation_name}_${file}`

On selection of the file, you can see the metrics uploaded and visualized for the file, respectively. Artifacts likewise are uploaded for reference of the original source.

### Supported Evaluations:

-   Beir
-   BigBench
-   Bigcode_latest
-   Custom Evals
-   Lm_harness
-   MtBench
-   Multilingual

### Not supported evaluations:

-   Content Safety
-   Garak

### Example executions

Example to provide bigcode results provided arguments to the script:

```
python3 mlflow_eval_integration.py --results_abs_dir "<ABSOLUTE_PATH_TO_DOWNLOADED_RESULTS>/bigcode_latest/automatic/bigcode_latest/results/" --mlflow_uri "<MLFLOW_URI>" --experiment_name="<EXPERIMENT_NAME>"
```
