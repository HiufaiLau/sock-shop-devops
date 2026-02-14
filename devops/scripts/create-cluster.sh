#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sock-shop}"
NAMESPACE="${NAMESPACE:-sock-shop}"

command -v kind >/dev/null 2>&1 || { echo "kind not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }

kind create cluster --name "$CLUSTER_NAME" || true
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

echo "✅ Cluster ready: $CLUSTER_NAME, namespace: $NAMESPACE"
cat > devops/scripts/create-cluster.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-sock-shop}"
NAMESPACE="${NAMESPACE:-sock-shop}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }

if command -v kind >/dev/null 2>&1; then
  kind create cluster --name "$CLUSTER_NAME" || true
  echo "✅ kind cluster ensured: $CLUSTER_NAME"
else
  echo "ℹ️ kind not installed. Using current kube-context:"
  kubectl config current-context || true
fi

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"
echo "✅ Namespace ensured: $NAMESPACE"
EOF

chmod +x devops/scripts/create-cluster.sh
git add devops/scripts/create-cluster.sh
git commit -m "fix: create-cluster works without kind (use existing cluster)"
git push
