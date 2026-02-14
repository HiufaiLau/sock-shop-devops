#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-sock-shop}"
OUT_DIR="${OUT_DIR:-backups}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${OUT_DIR}/${TS}"

mkdir -p "$DEST"

echo "==> Saving Kubernetes state..."
kubectl -n "$NAMESPACE" get all,cm,secret,ingress -o yaml > "${DEST}/k8s-state.yaml" || true

echo "==> Attempting Mongo backup (user-db)..."
USER_DB_POD="$(kubectl -n "$NAMESPACE" get pod -l name=user-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [ -n "$USER_DB_POD" ]; then
  kubectl -n "$NAMESPACE" exec "$USER_DB_POD" -- sh -lc 'command -v mongodump >/dev/null 2>&1 && mongodump --archive --gzip || true' \
    > "${DEST}/user-db.mongo.archive.gz" || true
  echo "Mongo backup saved to ${DEST}/user-db.mongo.archive.gz (if supported)."
else
  echo "user-db pod not found; skipping mongo backup."
fi

echo "✅ Backup complete: ${DEST}"
