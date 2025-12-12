#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
   --dtoperatortoken)
          DTOPERATORTOKEN="$2"
         shift 2
          ;;
       --dtingesttoken)
          DTTOKEN="$2"
         shift 2
          ;;
       --dturl)
          DTURL="$2"
         shift 2
          ;;
       --clustername)
         CLUSTERNAME="$2"
         shift 2
         ;;
      --type)
         TYPE="$2"
         shift 2
         ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
 if [ -z "$CLUSTERNAME" ]; then
   echo "Error: clustername not set!"
   exit 1
 fi
 if [ -z "$DTURL" ]; then
   echo "Error: Dt url not set!"
   exit 1
 fi
 if [ -z "$TYPE" ]; then
   TYPE="ADMISSION"
 fi
 if [ -z "$DTTOKEN" ]; then
   echo "Error: Data ingest api-token not set!"
   exit 1
 fi

 if [ -z "$DTOPERATORTOKEN" ]; then
   echo "Error: DT operator token not set!"
   exit 1
 fi


if [  "$TYPE" = 'ADMISSION' ]; then
  kubectl apply -f https://github.com/kubescape/cel-admission-library/releases/latest/download/policy-configuration-definition.yaml
  # Install basic configuration
  kubectl apply -f https://github.com/kubescape/cel-admission-library/releases/latest/download/basic-control-configuration.yaml
  # Install policies
  kubectl apply -f https://github.com/kubescape/cel-admission-library/releases/latest/download/kubescape-validating-admission-policies.yaml

  kubectl apply -f admission-controller/validationexample.yaml
  kubectl apply -f admission-controller/validationpolicybinding.yaml
else
  if [  "$TYPE" = 'KYVERNO' ]; then
    # install kyverno
    helm repo add kyverno https://kyverno.github.io/kyverno/
    helm repo update
    helm install kyverno kyverno/kyverno -n kyverno --create-namespace -f Kyverno/helm/values.yaml

    helm install kyverno-policies kyverno/kyverno-policies -n kyverno
    kubectl apply -k Kyverno/policies
  else
    helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
    helm install gatekeeper/gatekeeper --name-template=gatekeeper --namespace gatekeeper-system --create-namespace -f OPA/helm/values.yaml
    kubectl apply -f OPA/gatekeeper-controller-manager.yaml -n gatekeeper-system
    kubectl apply -f OPA/gatekeeper-audit.yaml -n gatekeeper-system

    kubectl apply -k github.com/open-policy-agent/gatekeeper-library/library
    kubectl apply -k OPA/policy
  fi
fi

#### Deploy the Dynatrace Operator
helm upgrade dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator \
  --version 1.7.0 \
  --create-namespace --namespace dynatrace \
  --install \
  --atomic
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
sed -i '' "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i '' "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml

kubectl apply -k policies


#Deploy collector
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=clustername="$CLUSTERNAME"  --from-literal=clusterid=$CLUSTERID  --from-literal=dt_api_token="$DTTOKEN"
kubectl label namespace  default oneagent=false
kubectl label namespace default policy=enforced
kubectl apply -f Kyverno/opentelemetry/rbac.yaml


if [  "$TYPE" = 'KYVERNO' ]; then
  kubectl apply -f Kyverno/opentelemetry/openTelemetry-manifest_statefulset.yaml
else
  if [  "$TYPE" = 'OPA' ]; then
    kubectl apply -f OPA/opentelemetry/openTelemetry-manifest_statefulset.yaml
    else
      kubectl apply -f opentelemetry/openTelemetry-manifest_statefulset.yaml
    fi
fi

kubectl apply -f opentelemetry/openTelemetry-manifest_ds.yaml
#Deploy unguard
helm repo add bitnami https://charts.bitnami.com/bitnami
kubectl create ns unguard

kubectl label namespace unguard policy=enforced
kubectl label namespace unguard oneagent=true
helm install unguard-mariadb bitnami/mariadb --version 11.5.7 --set primary.persistence.enabled=false --wait --namespace unguard
helm install unguard  oci://ghcr.io/dynatrace-oss/unguard/chart/unguard --wait --namespace unguard

#Deploy otel-demop
kubectl create ns otel-demo
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dt_api_token="$DTTOKEN" -n otel-demo
kubectl label namespace  otel-demo oneagent=false
kubectl label namespace otel-demo policy=enforced
kubectl apply -f opentelemetry/deploy_1_12.yaml -n otel-demo

#Deploy hipster-shop
kubectl create ns hipster-shop
kubectl label namespace hipster-shop policy=enforced
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dt_api_token="$DTTOKEN" -n hipster-shop
kubectl label namespace  hipster-shop oneagent=true
kubectl apply -f hipstershop/k8s-manifest.yaml -n hipster-shop

kuberctl apply -f test/cronjob.yaml

