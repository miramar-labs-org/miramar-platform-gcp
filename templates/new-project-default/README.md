# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})

{{DESCRIPTION}}

## Platform endpoints

All services require the SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 8080:localhost:8080 \
    -L 8082:localhost:8082 \
    -L 8890:localhost:8890 \
    -L 11434:localhost:11434 \
    -L 6333:localhost:6333 \
    -L 8889:localhost:8889 \
    -L 8084:localhost:8084 \
    <user>@spark-79b7.local
```

Add to your laptop's `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`):

```
127.0.0.1 nemo.test nim.test data-store.test
```

| Service              | URL                                                                                                                                                                                                                | Notes                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| JupyterLab           | [http://localhost:8888](http://localhost:8888)                                                                                                                                                                     | Notebook environment               |
| Kubernetes dashboard | [http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/](http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/) | Cluster state                      |
| KFP UI               | [http://localhost:8080](http://localhost:8080)                                                                                                                                                                     | Kubeflow Pipelines UI              |
| KFP API              | [http://localhost:8890/apis/v2beta1/healthz](http://localhost:8890/apis/v2beta1/healthz)                                                                                                                           | KFP REST API                       |
| MLflow               | [http://localhost:5000](http://localhost:5000)                                                                                                                                                                     | Experiment tracking                |
| NeMo / NIM           | [http://nemo.test:8082](http://nemo.test:8082)                                                                                                                                                                     | NeMo Microservices + NIM inference |
| Ollama               | [http://localhost:11434](http://localhost:11434)                                                                                                                                                                   | Local LLM inference                |
| Qdrant               | [http://localhost:6333/dashboard](http://localhost:6333/dashboard)                                                                                                                                                 | Vector database                    |
| Nsight UI            | [http://localhost:8889](http://localhost:8889)                                                                                                                                                                     | Nsight Operator profiling UI       |
| Open WebUI           | [http://localhost:8084](http://localhost:8084)                                                                                                                                                                     | Chat UI (Ollama / vLLM backend)    |
