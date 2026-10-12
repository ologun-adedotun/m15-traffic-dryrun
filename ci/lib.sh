VALUES=charts/maright-app/ci/kind-values.yaml
H() { echo; echo "=== $* ==="; }
k6start() {
  kubectl delete job "$1" -n load --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create job "$1" -n load --image=maright-k6:v1 -- k6 run -q -e TARGET="$GW$2" -e RATE="$3" -e DURATION="$4" -e HOST="${5:-mission.local}" /scripts/load.js >/dev/null
}
k6wait() {
  kubectl wait --for=condition=complete "job/$1" -n load --timeout="${2:-300s}" >/dev/null || echo "job $1 did not complete"
  kubectl logs -n load "job/$1" | grep RESULT || kubectl logs -n load "job/$1" | tail -n 15
}
k6run() { k6start "$@"; k6wait "$1"; }
worktotal() {
  local s=0 c p
  for p in $(kubectl get pods -n app -l app.kubernetes.io/instance="$1" --field-selector=status.phase=Running -o name); do
    c=$(timeout 20 kubectl exec -n app "$p" -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/metrics').read().decode())" | awk '/^app_requests_total\{path="\/work"\}/{print $2}')
    s=$(python3 -c "print(int($s + float('${c:-0}')))")
  done
  echo "$s"
}
policy() { kubectl apply -f - ; sleep 8; }
