ns=default
ing=nemo-microservices-helm-chart

core_port=$(kubectl -n "$ns" get svc nemo-core-api -o jsonpath='{.spec.ports[0].port}')
deploy_port=$(kubectl -n "$ns" get svc nemo-deployment-management -o jsonpath='{.spec.ports[0].port}')
eval_port=$(kubectl -n "$ns" get svc nemo-evaluator -o jsonpath='{.spec.ports[0].port}')
entity_port=$(kubectl -n "$ns" get svc nemo-entity-store -o jsonpath='{.spec.ports[0].port}')
nim_port=$(kubectl -n "$ns" get svc nemo-nim-proxy -o jsonpath='{.spec.ports[0].port}')

kubectl -n "$ns" patch ingress "$ing" --type='json' -p="[
  {\"op\":\"add\",\"path\":\"/spec/rules/-\",\"value\":{\"host\":\"core-docs.test\",\"http\":{\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\",\"backend\":{\"service\":{\"name\":\"nemo-core-api\",\"port\":{\"number\":$core_port}}}}]}}},

  {\"op\":\"add\",\"path\":\"/spec/rules/-\",\"value\":{\"host\":\"deploy-docs.test\",\"http\":{\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\",\"backend\":{\"service\":{\"name\":\"nemo-deployment-management\",\"port\":{\"number\":$deploy_port}}}}]}}},

  {\"op\":\"add\",\"path\":\"/spec/rules/-\",\"value\":{\"host\":\"eval-docs.test\",\"http\":{\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\",\"backend\":{\"service\":{\"name\":\"nemo-evaluator\",\"port\":{\"number\":$eval_port}}}}]}}},

  {\"op\":\"add\",\"path\":\"/spec/rules/-\",\"value\":{\"host\":\"entity-docs.test\",\"http\":{\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\",\"backend\":{\"service\":{\"name\":\"nemo-entity-store\",\"port\":{\"number\":$entity_port}}}}]}}},

  {\"op\":\"add\",\"path\":\"/spec/rules/-\",\"value\":{\"host\":\"nim-docs.test\",\"http\":{\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\",\"backend\":{\"service\":{\"name\":\"nemo-nim-proxy\",\"port\":{\"number\":$nim_port}}}}]}}}
]"
