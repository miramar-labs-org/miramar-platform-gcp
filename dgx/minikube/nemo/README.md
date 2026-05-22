# NVidia NeMo Microservices Cluster on minikube/Spark DGX

## Issues (1/13/2026)

- The current minikube `nvidia-device-plugin` addon ships with an issue that prevents the spark-dgx GPU from advertising itself as being available. I patched the nemo creation script to install a newer version of this addon that contained the fix. 
- I also use a values.yaml file to disable `guardrails` for now as it hasn't been ported to ARM/SparkDGX arch yet.
- In addition, the current NIM's ship with a TensorRT issue that prevents them from coming up, so I use patched versions of those for now.
- The create script warned that the GB10 GPU was not on the 'approved' list .. but it is clearly capable of running these models, so I patched that warning.
- The script also requires that 2 GPUs (on their list of supported GPUs) are available. But I don't have the money for another Spark DGX, so I patched that to 1 and will have to devise a way to share the GPU between inference and customization/eval workflows... likely scaling down inference pods to do cust/eval and vice versa... fingers crossed this works !

[NeMo Framework](https://docs.nvidia.com/nemo-framework/user-guide/latest/overview.html)

[NeMo Microservices](https://docs.nvidia.com/nemo/microservices/latest/get-started/index.html)

[NeMo Demo Cluster on minikube](https://docs.nvidia.com/nemo/microservices/25.12.0/get-started/index.html)

[NGC Catalog](https://catalog.ngc.nvidia.com/)

[llama-3.1-8b-instruct-dgx-spark](https://catalog.ngc.nvidia.com/orgs/nim/teams/meta/containers/llama-3.1-8b-instruct-dgx-spark?version=1.0.0-variant)

Get yourself un-gated on the model here:

[meta-llama/llama-3.1-8b-instruct](https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct)

SDK Docs

[Python SDK](https://docs.nvidia.com/nemo/microservices/latest/pysdk/index.html)

[Microservice APIs](https://docs.nvidia.com/nemo/microservices/latest/api/index.html)
## Installing NeMo on minikube

Create a pyenv virtual environment and activate it

    pyenv install 3.11.14
    pyenv virtualenv 3.11.14 pyNeMo 
    cd nemo-k8s-spark-dgx
    pyenv local pyNeMo
    pip install -r requirements.txt

To install the NeMo platform (with MLflow):

    cd nemo-k8s-spark-dgx
    
    chmod +x *.sh 

    ./create-platform.sh

and to clean up:

    ./destroy-platform.sh

If all goes well, after about 30m you will see:

    NAME                                                              READY   STATUS    RESTARTS       AGE
    modeldeployment-meta-llama-3-1-8b-instruct-dgx-spark-5d5cbj7dnh   1/1     Running   0              139m
    nemo-core-api-54674f5989-9kx4d                                    1/1     Running   0              149m
    nemo-core-controller-9d9b6b99c-cpkqk                              1/1     Running   7 (143m ago)   149m
    nemo-core-jobs-logcollector-7787759b6c-6967g                      1/1     Running   0              149m
    nemo-customizer-6bd475bfb4-jnt4p                                  1/1     Running   0              110m
    nemo-customizerdb-0                                               1/1     Running   0              149m
    nemo-data-designer-6c6df98589-22srb                               1/1     Running   0              149m
    nemo-data-store-556cb7ff85-pwzsb                                  1/1     Running   0              149m
    nemo-deployment-management-f489c5d5-ldlxs                         1/1     Running   0              149m
    nemo-entity-store-77bb854685-zqvlh                                1/1     Running   0              149m
    nemo-entity-storedb-0                                             1/1     Running   0              149m
    nemo-evaluator-7ccf95dc7d-464ss                                   2/2     Running   0              110m
    nemo-evaluatordb-0                                                1/1     Running   0              149m
    nemo-jobsdb-0                                                     1/1     Running   0              149m
    nemo-nemo-operator-controller-manager-7bd775c8-6zb7s              2/2     Running   0              149m
    nemo-nim-operator-bbdfdb6cb-rtg55                                 1/1     Running   0              149m
    nemo-nim-proxy-b5f6b5765-t7gcv                                    1/1     Running   0              149m
    nemo-opentelemetry-collector-8f484bdff-kl8z4                      1/1     Running   0              149m
    nemo-postgresql-0                                                 1/1     Running   0              149m
    
    NAME                              READY   STATUS    RESTARTS   AGE
    minio-58f6897bd5-v86jm            1/1     Running   0          111m
    mlflow-tracking-985b69644-v4llm   1/1     Running   0          111m

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] 🎉 Setup Complete! NeMo Microservices Platform is ready!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] 📍 Your endpoints:

  • NIM Gateway:   http://nim.test

  • Data Store:    http://data-store.test

  • Platform APIs: http://nemo.test (all /v1/* endpoints)

[INFO] 📚 Quick tests:

  • List models:        curl http://nim.test/v1/models

  • Data Store health:  curl http://data-store.test/v1/health

  • List namespaces:    curl http://nemo.test/v1/namespaces

  • Customization API:  curl http://nemo.test/v1/customization/jobs

[INFO] 💡 Useful commands:

  • View all pods:        kubectl get pods -n default

  • Check service status: kubectl get svc -n default

  • View logs:            kubectl logs <pod-name> -n default

  • Clean up:             ./destroy-nmp-deployment.sh

[INFO] 📖 Documentation: https://docs.nvidia.com/nemo/microservices/

## UI endpoints (from Windows browser):

### Minikube dashboard

![dashboard](./res/dash1.png)

windows browser (after `up.ps1`):

    http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/#/workloads?namespace=default

### JupyterLAB 

![jupyterLAB](./res/jlab.png)

windows browser (after `up.ps1`):

    http://127.0.0.1:8888/lab

### MLflow

![MLflow](./res/mlflow.png)

windows browser (after `up.ps1`):

    http://127.0.0.1:5000/


## up/down scripts (graceful start/stop when putting spark/laptop to sleep)

### resuming session:

spark (after reboot):

    ./up.sh

powershell (after spark reboot):

    ./up.ps1

### pausing session:

powershell:

    ./down.ps1

spark:

    ./down.sh

## Service Endpoints (from SSH terminal)
After deploying the services to minikube, the following service endpoints are available:

**Base URL**: http://nemo.test

- This is the main endpoint for interacting with the NeMo microservices platform (REST APIs)

**Nemo Data Store HuggingFace Endpoint**: http://data-store.test/v1/hf

- The Data Store microservice exposes a HuggingFace-compatible API at this endpoint.

- Set the HF_ENDPOINT environment variable to this URL.

        export HF_ENDPOINT=http://data-store.test/v1/hf

**Inference URL**: http://nim.test

- This is the endpoint for the NIM Proxy microservice deployed as a part of the platform.

## Python Client SDK

    pip install nemo-microservices

Test Synchronous Client:

    from nemo_microservices import NeMoMicroservices

    # Initialize the client
    client = NeMoMicroservices(
        base_url="http://nemo.test",
        inference_base_url="http://nim.test"
    )

    # List namespaces
    namespaces = client.namespaces.list()
    print(namespaces.data)

Test Asynchronous Client:

    import asyncio
    from nemo_microservices import AsyncNeMoMicroservices

    async def main():
        # Initialize the async client
        client = AsyncNeMoMicroservices(
            base_url="http://nemo.test",
            inference_base_url="http://nim.test"
        )
        
        # List namespaces
        namespaces = await client.namespaces.list()
        print(namespaces.data)

    # Run the async function
    asyncio.run(main())