#!/usr/bin/env bash
# Configures Vault's Kubernetes auth method AGAINST THE VCLUSTER'S OWN API SERVER - not
# the host cluster. This only works after the vcluster exists (needs its API address, CA,
# and a token-reviewer credential from inside it), which is why this is a separate step
# run after 03-create-vcluster.sh, not part of the Vault CR's declarative config.
#
# See README "Why Vault auth is configured after the vcluster exists" and "The two real
# gotchas" for the reasoning and the failures we hit building this (DNS resolution across
# the vcluster boundary, and a certificate SAN mismatch) before landing on this exact
# sequence.
set -euo pipefail

VCLUSTER_NAME="demo"
VCLUSTER_NAMESPACE="vault-demo"
AUTH_PATH="kubernetes-vcluster-demo"
ROLE_NAME="vcluster-demo"
DEMO_SA_NAMESPACE="default"   # namespace INSIDE the vcluster, not on the host
DEMO_SA_NAME="vault-reader"   # ServiceAccount INSIDE the vcluster the demo Pod runs as

TMP_KC="$(mktemp)"
trap 'shred -u "$TMP_KC" 2>/dev/null || rm -f "$TMP_KC"' EXIT

echo "==> Creating a scoped token-reviewer ServiceAccount inside the vcluster"
echo "    (vcluster's own convenience flag - creates the SA + a system:auth-delegator"
echo "    ClusterRoleBinding for it INSIDE the virtual cluster, and hands us a token)"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" \
  --service-account default/vault-tokenreview \
  --cluster-role system:auth-delegator \
  --print > "$TMP_KC"

TOKENREVIEW_JWT=$(python3 -c "
import yaml
with open('$TMP_KC') as f:
    print(yaml.safe_load(f)['users'][0]['user']['token'], end='')
")
python3 -c "
import yaml, base64
with open('$TMP_KC') as f:
    d = yaml.safe_load(f)
print(base64.b64decode(d['clusters'][0]['cluster']['certificate-authority-data']).decode(), end='')
" > /tmp/vcluster-demo-ca.crt

# IMPORTANT: the kubeconfig's own `server:` field points at a local port-forward
# (https://127.0.0.1:<port>) meant for CLI use - NOT reachable from a pod. Vault reaches
# the vcluster via its real in-cluster Service instead. Use the SHORT form
# ("<name>.<namespace>", no ".svc.cluster.local" suffix): vcluster's generated API server
# certificate's SANs only include the short forms plus a couple of vcluster.com wildcard
# names - not the fully-qualified name. Using the FQDN here causes Vault to reject the
# login with a TLS SAN-mismatch error (we hit this - see README).
KUBERNETES_HOST="https://${VCLUSTER_NAME}.${VCLUSTER_NAMESPACE}:443"

echo "==> Copying the vcluster CA into vault-0 and configuring the auth mount"
kubectl -n vault cp /tmp/vcluster-demo-ca.crt vault-0:/tmp/vcluster-demo-ca.crt -c vault
rm -f /tmp/vcluster-demo-ca.crt

ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.vault-root}' | base64 -d)
kubectl -n vault exec -i vault-0 -c vault -- sh -c "
export VAULT_TOKEN='$ROOT_TOKEN'
export VAULT_CACERT=/vault/tls/ca.crt
export VAULT_ADDR=https://127.0.0.1:8200

vault auth enable -path=$AUTH_PATH kubernetes 2>/dev/null || echo 'auth mount already exists at $AUTH_PATH/'

vault write auth/$AUTH_PATH/config \
  kubernetes_host=$KUBERNETES_HOST \
  kubernetes_ca_cert=@/tmp/vcluster-demo-ca.crt \
  token_reviewer_jwt='$TOKENREVIEW_JWT'

rm -f /tmp/vcluster-demo-ca.crt

vault write auth/$AUTH_PATH/role/$ROLE_NAME \
  bound_service_account_names=$DEMO_SA_NAME \
  bound_service_account_namespaces=$DEMO_SA_NAMESPACE \
  policies=vcluster-demo-read \
  ttl=1h

vault write auth/$AUTH_PATH/role/vault-secrets-reloader \
  bound_service_account_names=vault-secrets-reloader \
  bound_service_account_namespaces=default \
  policies=vault-secrets-reloader-read \
  ttl=1h
"

echo "==> Done. Vault now trusts service account tokens minted by the '$VCLUSTER_NAME' vcluster."
echo "Two roles are ready under auth/$AUTH_PATH/: '$ROLE_NAME' (the demo workload) and"
echo "'vault-secrets-reloader' (the in-vcluster reloader instance - see step 06)."
