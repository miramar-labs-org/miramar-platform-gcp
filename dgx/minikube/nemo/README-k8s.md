# Kubernetes Notes

## INGRESS

The NeMo cluster exposes its endpoints through an Ingress resource.

    kubectl get ingress -A
    
    NAME                            CLASS   HOSTS                      ADDRESS        PORTS   AGE
    nemo-microservices-helm-chart   nginx   data-store.test,nim.test   192.168.49.2   80      22h

The NeMo ingress runs in the `default` namespace and is named `nemo-microservices-helm-chart`
It declares two 'hosts' each on port 80 (http):

    data-store.test
    nim.test

The ingress routes these hosts to backend NeMo services ... to see these `Rules` :

    kubectl describe ingress nemo-microservices-helm-chart

        Rules:
        Host             Path  Backends
        ----             ----  --------
        data-store.test
                        /   nemo-data-store:3000 (10.244.0.118:3000)
        *
                        /v1/namespaces              nemo-entity-store:8000 (10.244.0.110:8000)
                        /v1/projects                nemo-entity-store:8000 (10.244.0.110:8000)
                        /v1/datasets                nemo-entity-store:8000 (10.244.0.110:8000)
                        /v1/repos                   nemo-entity-store:8000 (10.244.0.110:8000)
                        /v1/models                  nemo-entity-store:8000 (10.244.0.110:8000)
                        /v1/customization           nemo-customizer:8000 (10.244.0.105:8000)
                        /v1/evaluation              nemo-evaluator:7331 (10.244.0.119:7331)
                        /v2/evaluation              nemo-evaluator:7331 (10.244.0.119:7331)
                        /v1/guardrail               nemo-guardrails:7331 (<error: services "nemo-guardrails" not found>)
                        /v1/deployment              nemo-deployment-management:8000 (10.244.0.98:8000)
                        /v1/data-designer           nemo-data-designer:8000 (10.244.0.99:8000)
                        /v1beta1/audit              nemo-auditor:5000 (<error: services "nemo-auditor" not found>)
                        /v1beta1/safe-synthesizer   nemo-safe-synthesizer:8000 (<error: services "nemo-safe-synthesizer" not found>)
                        /v1/jobs                    nemo-core-api:8000 (10.244.0.102:8000)
                        /v2/inference/gateway       nemo-core-api:8000 (10.244.0.102:8000)
                        /v2/inference               nemo-core-api:8000 (10.244.0.102:8000)
                        /v2/models                  nemo-core-api:8000 (10.244.0.102:8000)
                        /v1/intake                  nemo-intake:8000 (<error: services "nemo-intake" not found>)
                        /studio                     nemo-studio:3000 (<error: services "nemo-studio" not found>)
        nim.test
                        /v1/completions   nemo-nim-proxy:8000 (10.244.0.97:8000)
                        /v1/chat          nemo-nim-proxy:8000 (10.244.0.97:8000)
                        /v1/embeddings    nemo-nim-proxy:8000 (10.244.0.97:8000)
                        /v1/classify      nemo-nim-proxy:8000 (10.244.0.97:8000)
                        /v1/models        nemo-nim-proxy:8000 (10.244.0.97:8000) 

In addition, the setup script mapped these hosts to the minikube ip in /etc/hosts:

    # Added by NeMo setup script
    192.168.49.2 nim.test           # Inference URL
    192.168.49.2 data-store.test    # HF API
    192.168.49.2 nemo.test          # base URL

### Service Endpoints
After deploying the services to minikube, the following service endpoints are available:

- Base URL: http://nemo.test

    - This is the main endpoint for interacting with the NeMo microservices platform.

- Nemo Data Store HuggingFace Endpoint: http://data-store.test/v1/hf

    - The Data Store microservice exposes a HuggingFace-compatible API at this endpoint.

    - Set the HF_ENDPOINT environment variable to this URL.

        
            export HF_ENDPOINT=http://data-store.test/v1/hf

- Inference URL: http://nim.test

    - This is the endpoint for the NIM Proxy microservice deployed as a part of the platform.
    - Example - describe the currently loaded NIM model (there is only ever one at a time) :

            curl -s http://nim.test/v1/models | jq

### Health Check endpoints
The ingress doesn't expose any of the usual health check endpoints, so to check them we need to hit the backend services directly:

    kubectl -n default port-forward svc/nemo-nim-proxy 18000:8000

Then:

    curl -i http://127.0.0.1:18000/health  | head -n 20



           