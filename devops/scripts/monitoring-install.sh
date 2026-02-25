#!/usr/bin/env bash
set -euo pipefail

command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }

kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring

echo "✅ Monitoring installed."
echo "Run: make monitoring-open"
