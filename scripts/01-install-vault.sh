#!/usr/bin/env bash
# Installs the bank-vaults vault-operator, its Vault CR's RBAC, and the Vault CR itself,
# all in the "vault" namespace. The operator auto-initializes, auto-unseals, and applies
# the CR's `externalConfig` (KV v2 engine, policy, demo secret) with no manual steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_OPERATOR_VERSION="1.24.0"

echo "==> Creating namespace: vault"
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying RBAC for the Vault CR's own ServiceAccount"
kubectl apply -f "$ROOT_DIR/helm/vault-rbac.yaml"

echo "==> Installing vault-operator $VAULT_OPERATOR_VERSION"
helm upgrade --install --wait --timeout 3m vault-operator \
  oci://ghcr.io/bank-vaults/helm-charts/vault-operator \
  --version "$VAULT_OPERATOR_VERSION" \
  --namespace vault

echo "==> Applying the Vault custom resource"
kubectl apply -f "$ROOT_DIR/helm/vault-cr.yaml"

echo "==> Waiting for vault-0 to become ready (operator handles init/unseal automatically)"
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s

echo "==> Waiting for the configurer to finish applying externalConfig (KV engine, policy, demo secret)"
kubectl -n vault wait --for=condition=Available deployment/vault-configurer --timeout=120s 2>/dev/null || true
sleep 10

CA_SECRET_NAME=$(kubectl -n vault get secret -o name | grep -E '/vault-tls$' | cut -d/ -f2 || true)
if [ "$CA_SECRET_NAME" != "vault-tls" ]; then
  echo "WARNING: expected the operator to name the CA secret 'vault-tls', found: '${CA_SECRET_NAME:-<none>}'."
  echo "Update the 'vault.security.banzaicloud.io/vault-tls-secret' annotation in"
  echo "examples/demo-deployment.yaml to match before continuing."
fi

echo "==> Configuring the HOST-facing Kubernetes auth mount (used by vault-secrets-reloader"
echo "    running on the host - see README for why this is separate from the vcluster-facing one)"
ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.vault-root}' | base64 -d)
kubectl -n vault exec vault-0 -c vault -- sh -c "
export VAULT_TOKEN='$ROOT_TOKEN'
export VAULT_CACERT=/vault/tls/ca.crt
export VAULT_ADDR=https://127.0.0.1:8200

vault auth enable -path=kubernetes kubernetes 2>/dev/null || echo 'kubernetes auth already enabled at kubernetes/'

vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

vault policy write vault-secrets-reloader-read - <<'EOP'
path \"secret/data/vcluster-demo/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"secret/metadata/vcluster-demo/*\" {
  capabilities = [\"read\", \"list\"]
}
EOP

vault write auth/kubernetes/role/vault-secrets-reloader \
  bound_service_account_names=vault-secrets-reloader \
  bound_service_account_namespaces=vault \
  policies=vault-secrets-reloader-read \
  ttl=1h
"

echo "==> Done. Vault is installed, unsealed, and configured."
echo "Root token (test environments only - see README): "
echo "  kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.vault-root}' | base64 -d"
