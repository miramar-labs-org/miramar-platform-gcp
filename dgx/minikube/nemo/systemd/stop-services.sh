#!/usr/bin/env zsh

systemctl --user stop dashboard.service
systemctl --user stop mlflow-portfwd.service
systemctl --user stop jupyterlab.service