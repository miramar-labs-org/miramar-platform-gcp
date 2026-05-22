#!/usr/bin/env zsh

echo "==> Restarting dashboard.service..."
systemctl --user daemon-reload
systemctl --user restart dashboard.service

echo "==> Restarting mlflow-portfwd.service..."
systemctl --user daemon-reload
systemctl --user restart mlflow-portfwd.service

echo "==> Restarting jupyterlab.service..."
systemctl --user daemon-reload
systemctl --user restart jupyterlab.service