#!/bin/bash
# Runs ON the K3s server (sent by CD through ssm-run.sh).
# Downloads the manifest bundle for this commit, applies the shop and the
# monitoring stack, waits for rollouts and smoke-tests the front-end NodePort.
#
# __BUNDLE_URL__ is replaced by CD with a short-lived presigned S3 URL.
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="/usr/local/bin:$PATH"

wait_api() {
  timeout 300 bash -c 'until kubectl get nodes >/dev/null 2>&1; do sleep 5; done'
}

echo "=== Waiting for K3s API ==="
wait_api
kubectl get nodes -o wide

# --- K3s networking guard ----------------------------------------------------
# Pods reach the API through the in-cluster `kubernetes` service, whose
# endpoint is K3s' advertise address. With --node-external-ip set, K3s
# advertised the (stale) Elastic IP, so CoreDNS/DNS broke and user/catalogue
# crash-looped. The API is only used in-cluster and via SSM (6443 is closed),
# so pin everything to the node's private IP and drop the external-IP flags.
echo "=== Ensuring K3s advertises the private IP ==="
PRIVATE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
[ -n "$PRIVATE_IP" ] || { echo "Could not determine node private IP"; exit 1; }
WANT_CFG=$(printf 'node-ip: "%s"\nadvertise-address: "%s"\n' "$PRIVATE_IP" "$PRIVATE_IP")

changed=0
if [ "$(cat /etc/rancher/k3s/config.yaml 2>/dev/null)" != "$WANT_CFG" ]; then
  mkdir -p /etc/rancher/k3s
  printf '%s\n' "$WANT_CFG" > /etc/rancher/k3s/config.yaml
  changed=1
fi
if grep -qE -- '--node-external-ip|--tls-san' /etc/systemd/system/k3s.service; then
  sed -i -E "/--node-external-ip|--tls-san/d" /etc/systemd/system/k3s.service
  changed=1
fi
if [ -f /etc/systemd/system/k3s.service.env ] && grep -qE -- '--node-external-ip|--tls-san' /etc/systemd/system/k3s.service.env; then
  sed -i -E "s/--(node-external-ip|tls-san)[= ][^ '\"]*//g" /etc/systemd/system/k3s.service.env
  changed=1
fi

if [ "$changed" -eq 1 ]; then
  echo "K3s config changed -> restarting K3s"
  cat /etc/rancher/k3s/config.yaml
  systemctl daemon-reload
  systemctl restart k3s
  wait_api
  # Let the API server re-publish its endpoint, then restart what was stuck.
  sleep 20
  kubectl -n kube-system rollout restart deploy
  kubectl -n kube-system rollout status deploy/coredns --timeout=5m
  kubectl -n sock-shop rollout restart deploy/user deploy/catalogue 2>/dev/null || true
  kubectl -n monitoring rollout restart deploy 2>/dev/null || true
fi

for i in $(seq 1 24); do
  API_EP=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[*].addresses[*].ip}')
  [ "$API_EP" = "$PRIVATE_IP" ] && break
  [ "$i" -eq 24 ] && { echo "kubernetes endpoint is '$API_EP', expected $PRIVATE_IP"; exit 1; }
  sleep 5
done
echo "kubernetes service endpoint: $API_EP (node private IP: $PRIVATE_IP)"
kubectl -n kube-system rollout status deploy/coredns --timeout=5m

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
# Grafana now provisions its dashboards from ConfigMaps; remove the old
# one-shot import Job and its ConfigMap (apply doesn't prune them).
kubectl -n monitoring delete job/grafana-import-dashboards configmap/grafana-import-dashboards \
  --ignore-not-found
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
