## Python Script

### Description:

W&B Evaluator Ingestion script `w_and_b_eval_integration.py` uploads results to W&B provided uri when provided the following as arguments:

1. An absolute path to the evaluation results directory, obtained by downloading results using Evaluator MS endpoint

#### Installation

To set up the required packages, run the following commands:

create and start up conda

```
conda create --name wandb python=3.8
```

```
conda activate wandb
```

install packages once activated

```
pip install -r requirements.txt
```

### Interactions with the script

1. Create a .env file inside the w_and_b directory
   Populate the .env file with:

```
WANDB_API_KEY=<API_KEY>
EXPERIMENT_NAME=<EXPERIMENT_NAME>
```

The api key must be obtained via w&b

2. Arguments to the script

-   W&B API key: not optional
    1. as an argument to the script `--api_key "<WANDB_API_KEY>"`
    2. via populated .env `WANDB_API_KEY=<WANDB_API_KEY>`
-   results_abs_dir: required `--results_abs_dir="<ABSOLUTE_PATH_TO_DOWNLOADED_RESULTS>/bigcode_latest/automatic/bigcode_latest/results/"`
-   experiment_name: optional `--experiment_name="<EXPERIMENT_NAME>"`

The experiment name desired to create in W&B is included as an optional variable,
the script defaults to "Nemo Evaluator MS Testing" if not provided.

_Note: The results file types that get uploaded are consistent with the files Evaluation MS API parse to shape results responses_

### W&B

In W&B UI, you should see the naming convention `${evaluation_name}_${file}`

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

Example to run for multilingual:

```
python3 w_and_b_eval_integration.py --results_abs_dir "<ABSOLUTE_PATH_TO_DOWNLOADED_RESULTS>/multilingual/automatic/multilingual/results/" --experiment_name="<EXPERIMENT_NAME>"
```
