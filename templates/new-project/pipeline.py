"""
KFP v2 pipeline definition.

Edit this file to define your pipeline. The function named `pipeline` is
what deploy-kfp.yaml compiles and submits — keep that name.
"""

from kfp import dsl


@dsl.component(base_image="python:3.11-slim")
def hello_world(message: str = "Hello from KFP") -> str:
    print(message)
    return message


@dsl.pipeline(
    name="my-pipeline",
    description="Starter pipeline — replace with your own components.",
)
def pipeline(message: str = "Hello from KFP"):
    hello_world(message=message)
