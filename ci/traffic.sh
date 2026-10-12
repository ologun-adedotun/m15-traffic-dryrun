#!/usr/bin/env bash
set -uo pipefail
source ci/lib.sh

H "0. Through the gateway"
k6run base / 20 15s

H "1. TLS with the private CA"
kubectl get secret mission-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt
openssl x509 -in /tmp/ca.crt -noout -subject -enddate
kubectl port-forward -n envoy-gateway-system "svc/$GWSVC" 8443:443 >/tmp/pf1.log 2>&1 &
PF=$!; sleep 5
curl -s --max-time 10 --cacert /tmp/ca.crt --resolve mission.local:8443:127.0.0.1 https://mission.local:8443/health; echo " [with the CA: exit $?]"
curl -s --max-time 10 --resolve mission.local:8443:127.0.0.1 https://mission.local:8443/health; echo " [without the CA: exit $?]"
curl -sv --max-time 10 --cacert /tmp/ca.crt --resolve mission.local:8443:127.0.0.1 https://mission.local:8443/health 2>&1 | grep -E 'subject:|issuer:|SSL connection|expire date'
kill $PF

H "2. Weighted split 90/10"
helm install canary charts/maright-app -n app -f "$VALUES" --set route.enabled=false --set config.GREETING=canary --wait --timeout 4m
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: split
  namespace: app
spec:
  parentRefs:
    - name: mission
      namespace: infra
  hostnames:
    - split.mission.local
  rules:
    - backendRefs:
        - name: stable
          port: 80
          weight: 90
        - name: canary
          port: 80
          weight: 10
EOF
sleep 6
kubectl port-forward -n envoy-gateway-system "svc/$GWSVC" 8080:80 >/tmp/pf2.log 2>&1 &
PF=$!; sleep 5
for i in $(seq 300); do curl -s --max-time 5 -H 'Host: split.mission.local' http://127.0.0.1:8080/; echo; done | sort | uniq -c
kill $PF

H "3. A 1-second timeout on the route"
helm upgrade stable charts/maright-app -n app -f "$VALUES" --set route.timeout=1s --wait --timeout 4m
sleep 6
k6run t-fast "/work?ms=200" 10 15s
k6run t-slow "/work?ms=2000" 10 15s

H "4. Retries on 503"
B=$(worktotal stable); k6run r-none "/work?fail=0.5" 20 20s; A=$(worktotal stable); echo "app received $((A-B)) /work requests for 400 sent (no retries)"
cat <<'EOF' | policy
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: retry
  namespace: app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: stable
  retry:
    numRetries: 3
    retryOn:
      triggers: ["retriable-status-codes"]
      httpStatusCodes: [503]
EOF
kubectl get backendtrafficpolicy retry -n app -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
B=$(worktotal stable); k6run r-three "/work?fail=0.5" 20 20s; A=$(worktotal stable); echo "app received $((A-B)) /work requests for 400 sent (3 retries)"

H "5. Retry storm: a full outage with retries on"
B=$(worktotal stable); k6run storm "/work?fail=1.0" 20 20s; A=$(worktotal stable); echo "app received $((A-B)) /work requests for 400 sent"
kubectl delete backendtrafficpolicy retry -n app

H "6. A local rate limit of 10 per second"
cat <<'EOF' | policy
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: ratelimit
  namespace: app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: stable
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 10
            unit: Second
EOF
kubectl get backendtrafficpolicy ratelimit -n app -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
k6run rl / 30 20s
kubectl delete backendtrafficpolicy ratelimit -n app

H "7. A circuit breaker"
cat <<'EOF' | policy
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: breaker
  namespace: app
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: stable
  circuitBreaker:
    maxParallelRequests: 5
    maxPendingRequests: 1
EOF
kubectl get backendtrafficpolicy breaker -n app -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
k6run cb "/work?ms=500" 30 20s
kubectl delete backendtrafficpolicy breaker -n app

H "8. A route in another namespace: without, then with, a ReferenceGrant"
kubectl label namespace infra mission-routes=allowed --overwrite
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: xns
  namespace: infra
spec:
  parentRefs:
    - name: mission
  hostnames:
    - xns.mission.local
  rules:
    - backendRefs:
        - name: stable
          namespace: app
          port: 80
EOF
sleep 6
kubectl get httproute xns -n infra -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl port-forward -n envoy-gateway-system "svc/$GWSVC" 8081:80 >/tmp/pf3.log 2>&1 &
PF=$!; sleep 5
curl -s -o /dev/null -w "without a ReferenceGrant: %{http_code}\n" -H 'Host: xns.mission.local' http://127.0.0.1:8081/
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: from-infra-routes
  namespace: app
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: infra
  to:
    - group: ""
      kind: Service
EOF
sleep 8
kubectl get httproute xns -n infra -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
curl -s -o /dev/null -w "with a ReferenceGrant: %{http_code}\n" -H 'Host: xns.mission.local' http://127.0.0.1:8081/
kill $PF

H "9. Programmed on kind: give the proxy a ClusterIP Service"
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: clusterip
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: ClusterIP
EOF
kubectl patch gatewayclass eg --type merge -p '{"spec":{"parametersRef":{"group":"gateway.envoyproxy.io","kind":"EnvoyProxy","name":"clusterip","namespace":"envoy-gateway-system"}}}'
sleep 20
kubectl get gateway mission -n infra -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl get gateway mission -n infra -o jsonpath='{.status.addresses}'; echo
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=mission -o custom-columns=NAME:.metadata.name,TYPE:.spec.type --no-headers
