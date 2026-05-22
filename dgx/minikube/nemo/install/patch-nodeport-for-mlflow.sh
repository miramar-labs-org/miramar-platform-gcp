kubectl -n mlflow-system patch svc mlflow-tracking --type='merge' -p '{
  "spec": {
    "type": "NodePort",
    "ports": [
      { "name": "http", "port": 80, "targetPort": "mlflow", "protocol": "TCP", "nodePort": 30090 }
    ]
  }
}'