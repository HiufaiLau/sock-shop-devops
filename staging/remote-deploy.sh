#!/bin/bash
# Runs ON the K3s server (sent by CD through ssm-run.sh).
# Downloads the manifest bundle for this commit, applies the shop and the
# monitoring stack, waits for rollouts and smoke-tests the front-end NodePort.
#
# __BUNDLE_URL__ is replaced by CD with a short-lived presigned S3 URL.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="/usr/local/bin:$PATH"

echo "=== Waiting for K3s API ==="
timeout 300 bash -c 'until kubectl get nodes >/dev/null 2>&1; do sleep 5; done'
kubectl get nodes -o wide

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

echo "=== Downloading manifest bundle ==="
curl -fsSL --retry 5 -o bundle.tgz "__BUNDLE_URL__"
tar -xzf bundle.tgz

echo "=== Deploying Sock Shop ==="
kubectl apply -f deploy/kubernetes/complete-demo.yaml

echo "=== Deploying monitoring (Prometheus + Grafana) ==="
# Namespace first so the remaining files can be applied in one go.
kubectl apply -f deploy/kubernetes/manifests-monitoring/00-monitoring-ns.yaml
kubectl apply -f deploy/kubernetes/manifests-monitoring/

failed=0
dump_debug() {
  ns="$1"
  kubectl -n "$ns" get pods -o wide || true
  kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -n 40 || true
  kubectl describe node | sed -n '/Allocated resources/,+12p' || true
  free -m || true
}

for ns in sock-shop monitoring; do
  echo "=== Waiting for rollouts in $ns ==="
  for d in $(kubectl -n "$ns" get deploy -o name); do
    if ! kubectl -n "$ns" rollout status "$d" --timeout=10m; then
      echo "Rollout failed: $ns/$d"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || { dump_debug "$ns"; exit 1; }
done

echo "=== Smoke test: front-end NodePort 30080 ==="
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null -w "front-end HTTP %{http_code}\n" http://127.0.0.1:30080/; then
    break
  fi
  [ "$i" -eq 30 ] && { echo "front-end did not answer on :30080"; dump_debug sock-shop; exit 1; }
  sleep 5
done

echo "=== Smoke test: Prometheus and Grafana (in-cluster only) ==="
curl -fsS -o /dev/null -w "prometheus HTTP %{http_code}\n" http://127.0.0.1:31090/-/ready
curl -fsS -o /dev/null -w "grafana HTTP %{http_code}\n"    http://127.0.0.1:31300/api/health

kubectl get pods -A -o wide
free -m
echo "Deploy finished OK"
