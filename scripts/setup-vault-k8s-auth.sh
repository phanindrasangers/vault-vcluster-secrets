#!/usr/bin/env bash
# Fully automates wiring a NEW Kubernetes auth backend into this repo's Vault, for either
# the HOST cluster Vault itself runs in, or any other cluster reachable via a kubeconfig
# (a vcluster, in this repo - but the same steps work for any external cluster). No manual
# `vault write`, RBAC, or `kubectl create token` steps needed afterwards.
#
# What it does, in order:
#
#   1. (--target vcluster only) Applies a DURABLE token-reviewer RBAC manifest into the
#      TARGET cluster: a ServiceAccount + a `kubernetes.io/service-account-token` Secret +
#      a `system:auth-delegator` ClusterRoleBinding. Deliberately NOT `kubectl create token`
#      (TokenRequest API) - that mints a short-lived token you'd have to keep rotating into
#      Vault's config. A Secret-backed token doesn't expire on its own, which is what you
#      want for something Vault depends on indefinitely. See CONNECT-VCLUSTER-TO-VAULT.md
#      Steps 1-2 for the manual version of this same manifest.
#      (--target host: skipped entirely. Vault's own pod ServiceAccount already carries
#      `system:auth-delegator` via helm/vault-rbac.yaml, so it reviews tokens for its own
#      cluster using its own identity - no separate RBAC needed.)
#   2. Enables a Kubernetes auth mount at --auth-path (idempotent - safe to re-run) and
#      configures it against the target's API address, CA cert, and reviewer JWT.
#   3. Writes a Vault policy granting full read/write/list/delete on a KV v2 mount
#      (default "secret/*" - see --kv-mount / --path-glob to scope this down to something
#      narrower before using this for anything beyond a POC).
#   4. Writes a role under that auth mount binding --bound-sa-name/--bound-sa-namespace
#      (the WORKLOAD's ServiceAccount inside the target cluster - NOT the reviewer SA from
#      step 1) to that policy.
#
# Examples
# --------
# Add another host-side role to the existing "kubernetes" mount:
#   ./setup-vault-k8s-auth.sh --target host \
#     --role-name my-app --bound-sa-name my-app --bound-sa-namespace default \
#     --path-glob 'my-app/*'
#
# Wire up a new vcluster (kubeconfig extracted per CONNECT-VCLUSTER-TO-VAULT.md Step 0,
# reachable at https://<vcluster>.<namespace>:443 from inside the host cluster - see that
# doc's "TLS: use the short hostname" gotcha before changing --kubernetes-host):
#   ./setup-vault-k8s-auth.sh --target vcluster \
#     --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml \
#     --kubernetes-host https://demo.vault-demo:443 \
#     --auth-path kubernetes-demo \
#     --role-name demo-app --bound-sa-name vault-reader --bound-sa-namespace default \
#     --path-glob 'demo-app/*'
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-vault-k8s-auth.sh --target host|vcluster --role-name NAME \
         --bound-sa-name NAME --bound-sa-namespace NS [options]

Required:
  --target host|vcluster           Which cluster the workload's ServiceAccount lives in
  --role-name NAME                 Vault role name to create under the auth mount
  --bound-sa-name NAME             Workload's ServiceAccount name (in the target cluster)
  --bound-sa-namespace NS          Workload's ServiceAccount namespace (in the target cluster)

Required when --target vcluster:
  --kubeconfig PATH                kubeconfig reaching the target cluster's real API server
                                    (e.g. extracted from a vcluster's vc-<name> Secret - see
                                    CONNECT-VCLUSTER-TO-VAULT.md Step 0)
  --kubernetes-host URL            In-cluster-reachable API URL Vault should use to reach the
                                    target (NOT the kubeconfig's own `server:` field - that's
                                    a local port-forward address, unreachable from Vault's
                                    pod). For a vcluster this is the short hostname form,
                                    e.g. https://demo.vault-demo:443 - see
                                    CONNECT-VCLUSTER-TO-VAULT.md "TLS: use the short hostname"

Optional:
  --auth-path PATH                 Vault auth mount path (default: "kubernetes" for --target
                                    host; REQUIRED for --target vcluster, no default, so two
                                    vclusters can never silently collide on one mount)
  --policy-name NAME               Vault policy name (default: "<role-name>-secrets")
  --kv-mount NAME                  KV v2 mount name (default: "secret")
  --path-glob GLOB                 Path glob under the mount the policy can access
                                    (default: "*" - full access to the whole mount; narrow
                                    this for anything beyond a demo, e.g. "my-app/*")
  --ttl DURATION                   Vault token TTL for logins via this role (default: "1h")
  --reviewer-sa-name NAME          Token-reviewer ServiceAccount name to create in the
                                    target cluster, --target vcluster only
                                    (default: "vault-tokenreview")
  --reviewer-sa-namespace NS       Namespace for the reviewer ServiceAccount, --target
                                    vcluster only (default: same as --bound-sa-namespace)
  --vault-namespace NS             Namespace Vault itself runs in (default: "vault")
  --vault-pod NAME                 Vault pod name (default: "vault-0")
  -h, --help                       Show this help
EOF
}

TARGET=""
ROLE_NAME=""
BOUND_SA_NAME=""
BOUND_SA_NAMESPACE=""
AUTH_PATH=""
POLICY_NAME=""
KV_MOUNT="secret"
PATH_GLOB="*"
TTL="1h"

KUBECONFIG_TARGET=""
KUBERNETES_HOST=""
REVIEWER_SA_NAME="vault-tokenreview"
REVIEWER_SA_NAMESPACE=""

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_CONTAINER="vault"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --role-name) ROLE_NAME="$2"; shift 2 ;;
    --bound-sa-name) BOUND_SA_NAME="$2"; shift 2 ;;
    --bound-sa-namespace) BOUND_SA_NAMESPACE="$2"; shift 2 ;;
    --auth-path) AUTH_PATH="$2"; shift 2 ;;
    --policy-name) POLICY_NAME="$2"; shift 2 ;;
    --kv-mount) KV_MOUNT="$2"; shift 2 ;;
    --path-glob) PATH_GLOB="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_TARGET="$2"; shift 2 ;;
    --kubernetes-host) KUBERNETES_HOST="$2"; shift 2 ;;
    --reviewer-sa-name) REVIEWER_SA_NAME="$2"; shift 2 ;;
    --reviewer-sa-namespace) REVIEWER_SA_NAMESPACE="$2"; shift 2 ;;
    --vault-namespace) VAULT_NAMESPACE="$2"; shift 2 ;;
    --vault-pod) VAULT_POD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$TARGET" != "host" ] && [ "$TARGET" != "vcluster" ]; then
  echo "ERROR: --target must be 'host' or 'vcluster' (got: '${TARGET}')" >&2; exit 1
fi
[ -n "$ROLE_NAME" ] || { echo "ERROR: --role-name is required" >&2; exit 1; }
[ -n "$BOUND_SA_NAME" ] || { echo "ERROR: --bound-sa-name is required" >&2; exit 1; }
[ -n "$BOUND_SA_NAMESPACE" ] || { echo "ERROR: --bound-sa-namespace is required" >&2; exit 1; }

if [ "$TARGET" = "vcluster" ]; then
  if [ -z "$KUBECONFIG_TARGET" ] || [ -z "$KUBERNETES_HOST" ]; then
    echo "ERROR: --target vcluster requires both --kubeconfig and --kubernetes-host." >&2
    echo "       See CONNECT-VCLUSTER-TO-VAULT.md Step 0 (getting a kubeconfig) and" >&2
    echo "       'TLS: use the short hostname' (picking --kubernetes-host) before retrying." >&2
    exit 1
  fi
  if [ -z "$AUTH_PATH" ]; then
    echo "ERROR: --target vcluster requires an explicit --auth-path (no default - two" >&2
    echo "       vclusters must never share one auth mount)." >&2
    exit 1
  fi
  [ -n "$REVIEWER_SA_NAMESPACE" ] || REVIEWER_SA_NAMESPACE="$BOUND_SA_NAMESPACE"
else
  [ -n "$AUTH_PATH" ] || AUTH_PATH="kubernetes"
  if [ -n "$KUBECONFIG_TARGET" ] || [ -n "$KUBERNETES_HOST" ]; then
    echo "NOTE: --kubeconfig/--kubernetes-host are ignored for --target host (Vault talks" >&2
    echo "      to its own cluster's API using its own pod identity)." >&2
  fi
fi
[ -n "$POLICY_NAME" ] || POLICY_NAME="${ROLE_NAME}-secrets"

vault_env() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c "$VAULT_CONTAINER" -- \
    env VAULT_TOKEN="$ROOT_TOKEN" VAULT_CACERT=/vault/tls/ca.crt VAULT_ADDR=https://127.0.0.1:8200 \
    "$@"
}
vault_env_stdin() {
  kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -c "$VAULT_CONTAINER" -- \
    env VAULT_TOKEN="$ROOT_TOKEN" VAULT_CACERT=/vault/tls/ca.crt VAULT_ADDR=https://127.0.0.1:8200 \
    "$@"
}

echo "==> Fetching Vault root token (namespace: $VAULT_NAMESPACE)"
ROOT_TOKEN=$(kubectl -n "$VAULT_NAMESPACE" get secret vault-unseal-keys -o jsonpath='{.data.vault-root}' | base64 -d)

CLEANUP_REMOTE_CA=""
cleanup() {
  if [ -n "$CLEANUP_REMOTE_CA" ]; then
    kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c "$VAULT_CONTAINER" -- rm -f "$CLEANUP_REMOTE_CA" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "$TARGET" = "host" ]; then
  echo "==> --target host: reusing Vault's own pod ServiceAccount as the token reviewer"
  echo "    (already bound to system:auth-delegator via helm/vault-rbac.yaml - no new RBAC needed)"

  echo "==> Enabling Kubernetes auth mount at '$AUTH_PATH' (idempotent)"
  vault_env vault auth enable -path="$AUTH_PATH" kubernetes 2>/dev/null \
    || echo "    auth mount already exists at $AUTH_PATH/"

  echo "==> Configuring '$AUTH_PATH' against this cluster's own API"
  vault_env vault write "auth/$AUTH_PATH/config" \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" \
    token_reviewer_jwt="@/var/run/secrets/kubernetes.io/serviceaccount/token"

else
  echo "==> --target vcluster: applying durable token-reviewer RBAC into the target cluster"
  echo "    (ServiceAccount '$REVIEWER_SA_NAME' in namespace '$REVIEWER_SA_NAMESPACE')"
  kubectl --kubeconfig "$KUBECONFIG_TARGET" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $REVIEWER_SA_NAME
  namespace: $REVIEWER_SA_NAMESPACE
---
apiVersion: v1
kind: Secret
metadata:
  name: $REVIEWER_SA_NAME-token
  namespace: $REVIEWER_SA_NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $REVIEWER_SA_NAME
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $REVIEWER_SA_NAME-$REVIEWER_SA_NAMESPACE
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: $REVIEWER_SA_NAME
    namespace: $REVIEWER_SA_NAMESPACE
EOF

  echo "==> Waiting for the token controller to populate the reviewer Secret"
  TOKENREVIEW_JWT=""
  for i in $(seq 1 15); do
    TOKENREVIEW_JWT=$(kubectl --kubeconfig "$KUBECONFIG_TARGET" \
      get secret "$REVIEWER_SA_NAME-token" -n "$REVIEWER_SA_NAMESPACE" \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "$TOKENREVIEW_JWT" ] && break
    sleep 2
  done
  if [ -z "$TOKENREVIEW_JWT" ]; then
    echo "ERROR: reviewer Secret never populated a token after 30s. Check that this" >&2
    echo "       Kubernetes version still auto-populates 'kubernetes.io/service-account-token'" >&2
    echo "       Secrets (some newer versions gate this) - see CONNECT-VCLUSTER-TO-VAULT.md" >&2
    echo "       Step 1 for the confirmed-working manifest." >&2
    exit 1
  fi

  LOCAL_CA="$(mktemp)"
  trap 'rm -f "$LOCAL_CA"; cleanup' EXIT
  kubectl --kubeconfig "$KUBECONFIG_TARGET" \
    get secret "$REVIEWER_SA_NAME-token" -n "$REVIEWER_SA_NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "$LOCAL_CA"

  REMOTE_CA="/tmp/${AUTH_PATH}-ca.crt"
  echo "==> Copying the target cluster's CA cert into $VAULT_POD:$REMOTE_CA"
  kubectl -n "$VAULT_NAMESPACE" cp "$LOCAL_CA" "$VAULT_POD:$REMOTE_CA" -c "$VAULT_CONTAINER"
  CLEANUP_REMOTE_CA="$REMOTE_CA"
  rm -f "$LOCAL_CA"

  echo "==> Enabling Kubernetes auth mount at '$AUTH_PATH' (idempotent)"
  vault_env vault auth enable -path="$AUTH_PATH" kubernetes 2>/dev/null \
    || echo "    auth mount already exists at $AUTH_PATH/"

  echo "==> Configuring '$AUTH_PATH' against $KUBERNETES_HOST"
  vault_env vault write "auth/$AUTH_PATH/config" \
    kubernetes_host="$KUBERNETES_HOST" \
    kubernetes_ca_cert="@$REMOTE_CA" \
    token_reviewer_jwt="$TOKENREVIEW_JWT"

  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -c "$VAULT_CONTAINER" -- rm -f "$REMOTE_CA"
  CLEANUP_REMOTE_CA=""
fi

echo "==> Writing policy '$POLICY_NAME' (full access to $KV_MOUNT/{data,metadata}/$PATH_GLOB)"
vault_env_stdin vault policy write "$POLICY_NAME" - <<EOF
path "$KV_MOUNT/data/$PATH_GLOB" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "$KV_MOUNT/metadata/$PATH_GLOB" {
  capabilities = ["read", "list", "delete"]
}
EOF

echo "==> Writing role '$ROLE_NAME' under auth/$AUTH_PATH/, bound to $BOUND_SA_NAMESPACE/$BOUND_SA_NAME"
vault_env vault write "auth/$AUTH_PATH/role/$ROLE_NAME" \
  bound_service_account_names="$BOUND_SA_NAME" \
  bound_service_account_namespaces="$BOUND_SA_NAMESPACE" \
  policies="$POLICY_NAME" \
  ttl="$TTL"

cat <<EOF

==> Done. No further manual Vault or RBAC steps needed.

Auth mount:  auth/$AUTH_PATH/
Role:        $ROLE_NAME (bound to ServiceAccount $BOUND_SA_NAMESPACE/$BOUND_SA_NAME)
Policy:      $POLICY_NAME  ->  full access to $KV_MOUNT/{data,metadata}/$PATH_GLOB

Point a workload at it with vault-secrets-webhook annotations, e.g.:
  vault.security.banzaicloud.io/vault-addr: "https://vault.vault.svc.cluster.local:8200"
  vault.security.banzaicloud.io/vault-role: "$ROLE_NAME"
  vault.security.banzaicloud.io/vault-path: "$AUTH_PATH"
EOF
