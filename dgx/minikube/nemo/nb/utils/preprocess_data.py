import pandas as pd
import os
import glob

def preprocess_latencies_trtllm_pbr_csv(df_raw):
    df = pd.DataFrame()
    # Rename columns of raw csv file
    df["tokens_per_s"] = df_raw["Throughput (tokens / sec)"]
    df["latency_first_token"] = df_raw["1st Token Latency (ms)"]
    df["latency"] = df_raw["Latency (ms)"]
    df["input_len"] = df_raw["Input Token Length"]
    df["output_len"] = df_raw["Output Token Length"]
    df["model"] = df_raw["Model"]
    df["batch_size"] = df_raw["Batch Size"]
    df["n_gpus"] = df_raw["Number of GPUs"]
    df["TP"] = df_raw["Tensor Model Parallel Size"]
    df["PP"] = df_raw["Pipeline Model Parallel Size"]
    df["device"] = df_raw["GPU"]
    df["full_args_final_max_input_len"] = df_raw["Input Token Length"]
    df["full_args_final_max_output_len"] = df_raw["Output Token Length"]
    df["precision"] = df_raw["Precision"]

    # Drop rows where latency or throughput are NaN
    df = df.dropna(subset=["latency", "tokens_per_s"])

    # Some reformats after dropping the NaNs
    df["input_len"] = df["input_len"].astype(int)
    df["output_len"] = df["output_len"].astype(int)
    df.loc[df["precision"] == "Mixed", "precision"] = "FP16"

    # Stuff from preprocess_latencies_jsonl()
    df["latency_per_token"] = df["latency"] / df["output_len"]
    df["prompts_per_s"] = 1000 / df["latency"] * df["batch_size"]
    df["prompts_per_s_per_gpu"] = df["prompts_per_s"] / df["n_gpus"]
    df["prompts_per_s_per_8_gpus"] = df["prompts_per_s_per_gpu"] * 8
    df["out_tokens_per_s"] = df["prompts_per_s"] * df["output_len"]
    df["out_tokens_per_s_per_8_gpus"] = df["prompts_per_s"] * df["output_len"] * 8 / df["n_gpus"]
    df["batch_size_per_8"] = df["batch_size"] * 8 / df["n_gpus"]
    df["TP"] = df["n_gpus"]
    df["latency_per_token_decoding"] = (df["latency"] - df["latency_first_token"]) / (df["output_len"] - 1)
    df["prompts_per_s_decoding"] =  1000 / (df["latency"] - df["latency_first_token"]) * df["batch_size"]
    df["prompts_per_s_per_gpu_decoding"] = df["prompts_per_s_decoding"] / df["n_gpus"]
    df["prompts_per_s_per_8_gpus_decoding"] = df["prompts_per_s_per_gpu_decoding"] * 8 
    df["out_tokens_per_s_per_user"] = 1000 / df["latency_per_token_decoding"]

    return df

def load_csvs_by_glob(files_glob):
    files = glob.glob(files_glob)
    df_raw = pd.DataFrame()
    for f in files:
        df_file = pd.read_csv(f)
        df_raw = pd.concat([df_raw, df_file])
    return df_raw

def preprocess_latencies_trtllm_pbr_csv(df_raw):
    df = pd.DataFrame()
    # Rename columns of raw csv file
    df["tokens_per_s"] = df_raw["Throughput (tokens / sec)"]
    df["latency_first_token"] = df_raw["1st Token Latency (ms)"]
    df["latency"] = df_raw["Latency (ms)"]
    df["input_len"] = df_raw["Input Token Length"]
    df["output_len"] = df_raw["Output Token Length"]
    df["model"] = df_raw["Model"]
    df["batch_size"] = df_raw["Batch Size"]
    df["n_gpus"] = df_raw["Number of GPUs"]
    df["TP"] = df_raw["Tensor Model Parallel Size"]
    df["PP"] = df_raw["Pipeline Model Parallel Size"]
    df["device"] = df_raw["GPU"]
    df["full_args_final_max_input_len"] = df_raw["Input Token Length"]
    df["full_args_final_max_output_len"] = df_raw["Output Token Length"]
    df["precision"] = df_raw["Precision"]

    # Drop rows where latency or throughput are NaN
    df = df.dropna(subset=["latency", "tokens_per_s"])

    # Some reformats after dropping the NaNs
    df["input_len"] = df["input_len"].astype(int)
    df["output_len"] = df["output_len"].astype(int)
    df.loc[df["precision"] == "Mixed", "precision"] = "FP16"

    # Stuff from preprocess_latencies_jsonl()
    df["latency_per_token"] = df["latency"] / df["output_len"]
    df["prompts_per_s"] = 1000 / df["latency"] * df["batch_size"]
    df["prompts_per_s_per_gpu"] = df["prompts_per_s"] / df["n_gpus"]
    df["prompts_per_s_per_8_gpus"] = df["prompts_per_s_per_gpu"] * 8
    df["out_tokens_per_s"] = df["prompts_per_s"] * df["output_len"]
    df["out_tokens_per_s_per_8_gpus"] = df["prompts_per_s"] * df["output_len"] * 8 / df["n_gpus"]
    df["batch_size_per_8"] = df["batch_size"] * 8 / df["n_gpus"]
    df["TP"] = df["n_gpus"]
    df["latency_per_token_decoding"] = (df["latency"] - df["latency_first_token"]) / (df["output_len"] - 1)
    df["prompts_per_s_decoding"] =  1000 / (df["latency"] - df["latency_first_token"]) * df["batch_size"]
    df["prompts_per_s_per_gpu_decoding"] = df["prompts_per_s_decoding"] / df["n_gpus"]
    df["prompts_per_s_per_8_gpus_decoding"] = df["prompts_per_s_per_gpu_decoding"] * 8 
    df["out_tokens_per_s_per_user"] = 1000 / df["latency_per_token_decoding"]

    return df



def preprocess_latencies_nim_pbr(df_raw=None):
    if df_raw is None: df_raw = load_csvs_by_glob("dataset/nim_dli.csv")

    df = pd.DataFrame()
    # Rename columns of raw csv file
    df["model"] = df_raw['task_inputs-model']
    df["device"] = df_raw['task_inputs-GPU']
    df["n_gpus"] = df_raw['task_inputs-n_gpus'].astype(int)
    df["out_tokens_per_s"] = df_raw['output_token_throughput-avg']
    df["latency_first_token"] = df_raw['time_to_first_token-avg'] / 1_000_000 # ns → ms
    df["latency_per_token_decoding"] = df_raw['inter_token_latency-avg'] / 1_000_000 # ns → ms
    df["input_len"] = df_raw['input_config-synthetic_input_tokens_mean']
    df["output_len"] = df_raw['input_config-output_tokens_mean']

    df["concurrency"] = df_raw['input_config-concurrency']
    df["precision"] = df_raw["task_inputs-precision"]
    df["prompts_per_s"] = df_raw['request_throughput-avg']
    df["latency"] = df_raw['request_latency-avg'] / 1_000_000
    df["out_tokens_per_s_per_user"] = df_raw['output_token_throughput_per_request-avg']
    df["TP"] = df["n_gpus"]
    df["PP"] = 1 # for our experiments

    # Some normalisation
    # a combo of in and out len for GUI simplification
    df["input_output_len"] = df["input_len"].astype(str) + " in → " + df["output_len"].astype(str) + " out"
    df["prompts_per_s_per_gpu"] = df["prompts_per_s"] / df["n_gpus"]
    df["prompts_per_s_per_8_gpus"] = df["prompts_per_s_per_gpu"] * 8
    df["out_tokens_per_s_per_gpu"] = df["out_tokens_per_s"] / df["n_gpus"]
    df["out_tokens_per_s_per_8_gpus"] = df["out_tokens_per_s_per_gpu"]  * 8 
    df["concurrency_per_8"] = df["concurrency"] * 8 / df["n_gpus"]

    return df

