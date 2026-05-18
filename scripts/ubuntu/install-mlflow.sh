#!/usr/bin/env bash
set -euo pipefail

PORT=5000
MLFLOW_DIR="${HOME}/mlflow"
SERVICE_USER="${USER}"
SERVICE_NAME="mlflow"

# Use the pyenv environment in ~/mlflow
cd "${MLFLOW_DIR}"

echo "==> Installing MLflow into ~/mlflow pyenv environment..."
pip install --upgrade mlflow

MLFLOW_BIN="$(pyenv which mlflow)"

echo "==> Creating artifact directory..."
mkdir -p "${MLFLOW_DIR}/artifacts"

echo "==> Writing systemd service..."
sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<EOF
[Unit]
Description=MLflow Tracking Server
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${MLFLOW_DIR}
Environment="PATH=${HOME}/.pyenv/shims:${HOME}/.pyenv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${MLFLOW_BIN} server \
    --host 127.0.0.1 \
    --port ${PORT} \
    --backend-store-uri sqlite:///${MLFLOW_DIR}/mlflow.db \
    --default-artifact-root ${MLFLOW_DIR}/artifacts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enabling and starting MLflow service..."
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl restart ${SERVICE_NAME}

echo ""
echo "==> Done. MLflow is running on http://localhost:${PORT}"
echo "    Status : sudo systemctl status mlflow"
echo "    Logs   : journalctl -u mlflow -f"
echo ""
echo "    To access from your laptop:"
echo "    ssh -L ${PORT}:localhost:${PORT} ${SERVICE_USER}@$(hostname).local"
