

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
      --old)
         OLD="$2"
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

 if [ -z "$TYPE" ]; then
     echo "Error:TYPE is  not set!"
    exit 1
 fi
 if [ -z "$OLD" ]; then
     echo "Error:OLD is  not set!"
    exit 1
 fi

if [  "$OLD" = 'ADMISSION' ]; then
  kubectl delete -f admission-controller/validationexample.yaml
  kubectl delete -f admission-controller/validationpolicybinding.yaml
  kubectl delete -f https://github.com/kubescape/cel-admission-library/releases/latest/download/kubescape-validating-admission-policies.yaml
  kubectl delete -f https://github.com/kubescape/cel-admission-library/releases/latest/download/policy-configuration-definition.yaml

else
  if [  "$OLD" = 'KYVERNO' ]; then
    kubectl delete -k Kyverno/policies
    helm uninstall kyverno-policies -n kyverno
    # install kyverno
    helm unistall kyverno  -n kyverno

  else

    kubectl delete -k OPA/policy
    kubectl delete -k github.com/open-policy-agent/gatekeeper-library/library

    helm uninstall gatekeeper --namespace gatekeeper-system

  fi
fi


if [  "$TYPE" = 'KYVERNO' ]; then
# install kyverno
  helm repo add kyverno https://kyverno.github.io/kyverno/
  helm repo update
  helm install kyverno kyverno/kyverno -n kyverno --create-namespace -f Kyverno/helm/values.yaml

  helm install kyverno-policies kyverno/kyverno-policies -n kyverno
  kubectl apply -k Kyverno/policies
  kubectl apply -f Kyverno/opentelemetry/openTelemetry-manifest_statefulset.yaml
else
  if [  "$TYPE" = 'OPA' ]; then
     helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
     helm install gatekeeper/gatekeeper --name-template=gatekeeper --namespace gatekeeper-system --create-namespace -f OPA/helm/values.yaml
     kubectl apply -f OPA/gatekeeper-controller-manager.yaml -n gatekeeper-system
     kubectl apply -f OPA/gatekeeper-audit.yaml -n gatekeeper-system

     kubectl apply -k github.com/open-policy-agent/gatekeeper-library/library
     kubectl apply -k OPA/policy
  else
    kubectl apply -f https://github.com/kubescape/cel-admission-library/releases/latest/download/policy-configuration-definition.yaml
    # Install basic configuration
    kubectl apply -f https://github.com/kubescape/cel-admission-library/releases/latest/download/basic-control-configuration.yaml
    # Install policies
    kubectl apply -f https://github.com/kubescape/cel-admission-library/releases/latest/download/kubescape-validating-admission-policies.yaml

    kubectl apply -f admission-controller/validationexample.yaml
    kubectl apply -f admission-controller/validationpolicybinding.yaml

  fi
  kubectl apply -f opentelemetry/openTelemetry-manifest_statefulset.yaml
fi