#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sock-shop}"
NAMESPACE="${NAMESPACE:-sock-shop}"

command -v kind >/dev/null 2>&1 || { echo "kind not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }

kind create cluster --name "$CLUSTER_NAME" || true
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

echo "✅ Cluster ready: $CLUSTER_NAME, namespace: $NAMESPACE"
