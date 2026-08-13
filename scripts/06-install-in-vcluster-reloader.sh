#!/usr/bin/env bash
# Installs a SECOND vault-secrets-reloader instance, this time INSIDE the vcluster.
#
# Why a second one: vault-secrets-reloader watches Deployments/StatefulSets/DaemonSets.
# vcluster does NOT sync those objects to the host - only the Pods they produce. The
# host-side reloader from 02-install-webhook-and-reloader.sh can physically never see a
# Deployment that only exists inside a vcluster's own API server. Each vcluster with
# Vault-consuming workloads needs its own reloader, authenticating through that vcluster's
# own Vault auth mount. See README "A reloader per vcluster, not one on the host".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VCLUSTER_NAME="demo"
VCLUSTER_NAMESPACE="vault-demo"
RELOADER_VERSION="0.5.0"

echo "==> Mirroring Vault's public CA cert (never the private key) into a virtual Secret"
echo "    named 'vault-tls' in the vcluster's own 'default' namespace - this reloader's"
echo "    own in-cluster API calls go against the vcluster's API, which has no 'vault'"
echo "    namespace to read the real vault-tls secret from."
kubectl -n vault get secret vault-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/vault-ca-only.crt
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl create secret generic vault-tls -n default --from-file=ca.crt=/tmp/vault-ca-only.crt \
  --dry-run=client -o yaml | \
  vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- kubectl apply -f -
rm -f /tmp/vault-ca-only.crt

echo "==> Installing vault-secrets-reloader $RELOADER_VERSION inside the vcluster"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  helm upgrade --install --wait --timeout 3m vault-secrets-reloader \
  oci://ghcr.io/bank-vaults/helm-charts/vault-secrets-reloader \
  --version "$RELOADER_VERSION" \
  --namespace default \
  -f "$ROOT_DIR/helm/values-vault-secrets-reloader-in-vcluster.yaml"

VAULT_IP=$(kubectl -n vault get svc vault -o jsonpath='{.spec.clusterIP}')
echo "==> Patching in the same DNS hostAlias fix demo-deployment.yaml uses (vcluster's"
echo "    CoreDNS has no record for vault.vault.svc.cluster.local)"
cat > /tmp/hostalias-patch.json <<EOF
{"spec":{"template":{"spec":{"hostAliases":[{"ip":"$VAULT_IP","hostnames":["vault.vault.svc.cluster.local"]}]}}}}
EOF
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl patch deployment vault-secrets-reloader -n default --patch-file /tmp/hostalias-patch.json
rm -f /tmp/hostalias-patch.json

echo "==> Waiting for it to come back up after the patch-triggered restart"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl rollout status deployment/vault-secrets-reloader -n default --timeout=120s

echo "==> Done. Logs should show it authenticate and start watching vault-demo-app:"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl logs -n default deployment/vault-secrets-reloader --tail=15
