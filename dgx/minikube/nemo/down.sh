#!/usr/bin/env bash

pushd systemd
source stop-services.sh
popd

minikube stop
