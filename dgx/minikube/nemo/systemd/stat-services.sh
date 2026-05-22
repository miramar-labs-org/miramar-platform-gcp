#!/usr/bin/env zsh

minikube status --output=json | jq
systemctl --user status mlflow-portfwd.service --no-pager
systemctl --user status dashboard.service --no-pager
systemctl --user status jupyterlab.service --no-pager