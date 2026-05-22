#!/usr/bin/env bash

pushd minikube
source create-nmp-spark-deployment.sh --values-file values.yaml
popd 

# integrate mlflow 
pushd mlflow
source integrate-mlflow.sh
popd

# reset systemd services
source up.sh
