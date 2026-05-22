mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/kubectl-proxy-minikube-dashboard.service <<'EOF'
[Unit]
Description=kubectl proxy for Minikube dashboard (fixed port)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kubectl proxy --address=127.0.0.1 --port=8001
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now kubectl-proxy-minikube-dashboard.service
systemctl --user status kubectl-proxy-minikube-dashboard.service --no-pager
