#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sock-shop}"
NAMESPACE="${NAMESPACE:-sock-shop}"

echo "🔍 Checking kubectl..."
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }

if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  echo "Using k3s kubeconfig"
  sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
  sudo chown $USER:$USER $HOME/.kube/config
  export KUBECONFIG=$HOME/.kube/config
fi


echo "🔍 Checking cluster connectivity..."
if ! kubectl version --short >/dev/null 2>&1; then
  echo "❌ Kubernetes cluster not reachable"
  exit 1
fi

echo "🔍 Current context: $(kubectl config current-context || echo unknown)"
echo "🔍 Current node:"
kubectl get nodes -o wide

echo "🔧 Ensuring namespace '$NAMESPACE' exists..."
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

echo "✅ Cluster reachable and namespace ready: $NAMESPACE"
