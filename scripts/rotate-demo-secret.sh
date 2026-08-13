#!/usr/bin/env bash
# Rotates the demo KV secret in Vault and waits to show vault-secrets-reloader (the
# in-vcluster instance) pick it up and roll the demo Deployment automatically.
# Usage: ./rotate-demo-secret.sh [new-password]
set -euo pipefail

NEW_PASSWORD="${1:-S3cr3t-Rotated-$(date +%s)}"
VCLUSTER_NAME="demo"
VCLUSTER_NAMESPACE="vault-demo"

ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.vault-root}' | base64 -d)

echo "==> Writing new secret version to secret/data/vcluster-demo/db"
kubectl -n vault exec vault-0 -c vault -- sh -c "
export VAULT_TOKEN='$ROOT_TOKEN'
export VAULT_CACERT=/vault/tls/ca.crt
export VAULT_ADDR=https://127.0.0.1:8200
vault kv put -mount=secret vcluster-demo/db username=demo_app password='$NEW_PASSWORD'
"

echo "==> Waiting for vault-secrets-reloader to notice (collectorSyncPeriod=30s,"
echo "    reloaderRunPeriod=1m in this POC - production defaults are 30m/1h, see README)"
echo "    This can take up to ~90s. Tracking the demo pod's age rather than tailing logs,"
echo "    since a short log tail can miss the event between polls if it lands between checks."
START_EPOCH=$(date +%s)
for i in $(seq 1 24); do
  sleep 5
  POD_START=$(vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
    kubectl get pods -n default -l app=vault-demo-app -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || true)
  if [ -n "$POD_START" ]; then
    POD_START_EPOCH=$(date -d "$POD_START" +%s 2>/dev/null || echo 0)
    if [ "$POD_START_EPOCH" -ge "$START_EPOCH" ]; then
      echo "==> New pod detected (created after rotation). Logs:"
      vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
        kubectl logs -n default deployment/vault-demo-app --tail=10
      exit 0
    fi
  fi
done

echo "No new pod observed within 2 minutes - check reloader logs directly:"
echo "  vcluster connect $VCLUSTER_NAME -n $VCLUSTER_NAMESPACE -- kubectl logs -n default deployment/vault-secrets-reloader"
exit 1
