#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-sock-shop}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

echo "🔍 Checking kubectl..."
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }

echo "🔍 Current context: $(kubectl config current-context || echo unknown)"
echo "🔍 Current nodes:"
kubectl get nodes

echo "----------------------------------------"
echo "🧹 Removing Sock Shop application..."

if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" delete -f deploy/kubernetes/complete-demo.yaml --ignore-not-found=true || true
  kubectl delete ns "$NAMESPACE" --ignore-not-found=true
  echo "✅ Namespace '$NAMESPACE' removed"
else
  echo "ℹ️ Namespace '$NAMESPACE' does not exist"
fi

echo "----------------------------------------"
echo "🧹 Removing monitoring stack..."

if helm ls -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
  helm uninstall monitoring -n "$MONITORING_NAMESPACE" || true
  kubectl delete ns "$MONITORING_NAMESPACE" --ignore-not-found=true
  echo "✅ Monitoring removed"
else
  echo "ℹ️ Monitoring release not found"
fi

echo "----------------------------------------"
echo "✅ Cleanup complete."
