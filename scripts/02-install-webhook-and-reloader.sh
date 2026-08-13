#!/usr/bin/env bash
# Installs vault-secrets-webhook and the HOST-side vault-secrets-reloader, both in the
# "vault" namespace, both from bank-vaults' own OCI Helm charts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WEBHOOK_VERSION="1.23.1"
RELOADER_VERSION="0.5.0"

echo "==> Installing vault-secrets-webhook $WEBHOOK_VERSION"
helm upgrade --install --wait --timeout 3m vault-secrets-webhook \
  oci://ghcr.io/bank-vaults/helm-charts/vault-secrets-webhook \
  --version "$WEBHOOK_VERSION" \
  --namespace vault \
  -f "$ROOT_DIR/helm/values-vault-secrets-webhook.yaml"

echo "==> Adding stakater repo is NOT needed - vault-secrets-reloader is bank-vaults' own chart"
echo "==> Installing vault-secrets-reloader $RELOADER_VERSION (host instance)"
helm upgrade --install --wait --timeout 3m vault-secrets-reloader \
  oci://ghcr.io/bank-vaults/helm-charts/vault-secrets-reloader \
  --version "$RELOADER_VERSION" \
  --namespace vault \
  -f "$ROOT_DIR/helm/values-vault-secrets-reloader.yaml"

echo "==> Done. Webhook and host-side reloader are running in the 'vault' namespace."
echo "Note: this host-side reloader instance can only see Deployments/StatefulSets/"
echo "DaemonSets that exist on the HOST. It will NOT see workloads running inside a"
echo "vcluster (see README) - scripts/06-install-in-vcluster-reloader.sh handles that."
