#!/usr/bin/env bash
set -uo pipefail
source ci/lib.sh
up() { helm upgrade stable charts/maright-app -n app -f "$VALUES" "$@" --wait --timeout 4m 2>&1 | grep -E 'Error|STATUS' ; }
onepod() { kubectl get pods -n app -l app.kubernetes.io/instance=stable --field-selector=status.phase=Running -o name | head -n 1; }

H "1. Topology spread across the workers"
up --set replicaCount=4 --set topologySpread.enabled=true
kubectl get pods -n app -l app.kubernetes.io/instance=stable -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers | awk '{print $2}' | sort | uniq -c

H "2. A rollout under load, with no graceful shutdown"
up --set replicaCount=3 --set shutdown.preStopSleepSeconds=0
k6start ro-off / 80 60s; sleep 15
kubectl rollout restart deployment/stable -n app; kubectl rollout status deployment/stable -n app --timeout=180s >/dev/null
k6wait ro-off

H "3. The same rollout, with a 5-second preStop sleep"
up --set replicaCount=3 --set shutdown.preStopSleepSeconds=5
k6start ro-on / 80 60s; sleep 15
kubectl rollout restart deployment/stable -n app; kubectl rollout status deployment/stable -n app --timeout=180s >/dev/null
k6wait ro-on

H "4. A pod killed hard under load"
k6start kill / 80 40s; sleep 12
kubectl delete -n app "$(onepod)" --grace-period=0 --force 2>&1 | tail -n 1
k6wait kill

H "5. Autoscaling on CPU"
helm install metrics-server metrics-server/metrics-server --version 3.14.0 -n kube-system --set 'args={--kubelet-insecure-tls}' --wait --timeout 4m >/dev/null && echo "metrics-server installed"
up --set autoscaling.enabled=true
for i in $(seq 12); do T=$(kubectl get hpa stable -n app -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null); [ -n "$T" ] && break; sleep 10; done
kubectl get hpa stable -n app --no-headers
k6start hpa "/work?cpu_ms=40" 40 150s
for i in $(seq 5); do sleep 30; echo "$(date +%T) $(kubectl get hpa stable -n app --no-headers)"; done
k6wait hpa 300s
for i in $(seq 5); do sleep 30; echo "$(date +%T) $(kubectl get hpa stable -n app --no-headers)"; done
kubectl describe hpa stable -n app | sed -n '/Events:/,$p' | tail -n 8
echo "--- a Helm upgrade while the HPA owns replicas ---"
R1=$(kubectl get deploy stable -n app -o jsonpath='{.spec.replicas}')
helm upgrade stable charts/maright-app -n app -f "$VALUES" --set autoscaling.enabled=true --set config.GREETING=after-scaling --wait --timeout 4m >/dev/null 2>/tmp/up.err; echo "upgrade exit $?"; tail -n 2 /tmp/up.err
R2=$(kubectl get deploy stable -n app -o jsonpath='{.spec.replicas}')
echo "replicas before upgrade $R1, after $R2"
