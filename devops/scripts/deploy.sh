#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-sock-shop}"

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
kubectl -n "$NAMESPACE" apply -f deploy/kubernetes/complete-demo.yaml

echo "⏳ Waiting for front-end rollout..."
kubectl -n "$NAMESPACE" rollout status deploy/front-end --timeout=5m || true

kubectl -n "$NAMESPACE" get pods -o wide
