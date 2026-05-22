#!/usr/bin/env bash

pushd systemd
source restart-services.sh
popd

# destroy mlflow 
pushd mlflow
source destroy-mlflow.sh
popd

pushd minikube
source destroy-nmp-deployment.sh
popd 


