minikube addons disable nvidia-device-plugin

kubectl apply -f \
  https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/refs/tags/v0.18.0/deployments/static/nvidia-device-plugin.yml
