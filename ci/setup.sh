#!/usr/bin/env bash
set -euo pipefail
TLS=${TLS:-0}
VALUES=charts/maright-app/ci/kind-values.yaml
docker build -q -t maright-app:v2 ./app
docker build -q -t maright-k6:v1 ./load
kind load docker-image maright-app:v2 maright-k6:v1 --name chart-testing
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 -n envoy-gateway-system --create-namespace --wait --timeout 6m
kubectl create namespace infra
kubectl create namespace app
kubectl label namespace app mission-routes=allowed pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.37
kubectl create namespace load
kubectl apply -f ci/gateway-http.yaml
if [ "$TLS" = 1 ]; then
  helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.2 -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 6m
  kubectl apply -f ci/tls.yaml
  kubectl wait --for=condition=Ready certificate/mission-ca -n cert-manager --timeout=120s
  kubectl wait --for=condition=Ready certificate/mission-tls -n infra --timeout=120s
  kubectl apply -f ci/gateway-tls.yaml
fi
kubectl wait --for=condition=Programmed gateway/mission -n infra --timeout=180s
helm install stable charts/maright-app -n app -f "$VALUES" --wait --timeout 4m
GWSVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=mission,gateway.envoyproxy.io/owning-gateway-namespace=infra -o jsonpath='{.items[0].metadata.name}')
echo "GWSVC=$GWSVC" >> "$GITHUB_ENV"
echo "GW=http://$GWSVC.envoy-gateway-system.svc.cluster.local" >> "$GITHUB_ENV"
kubectl get gateway -n infra
kubectl get httproute -A
