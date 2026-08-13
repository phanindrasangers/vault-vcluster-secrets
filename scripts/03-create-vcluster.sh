#!/usr/bin/env bash
# Creates the demo vcluster. Uses the plain `vcluster` chart at the same version already
# in use elsewhere in this environment - change VCLUSTER_NAME/VCLUSTER_NAMESPACE together
# with the caNamespaces entry in helm/vault-cr.yaml if you rename either.
set -euo pipefail

VCLUSTER_NAME="demo"
VCLUSTER_NAMESPACE="vault-demo"
VCLUSTER_CHART_VERSION="0.35.1"

echo "==> Creating vcluster '$VCLUSTER_NAME' in namespace '$VCLUSTER_NAMESPACE'"
vcluster create "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" \
  --chart-version "$VCLUSTER_CHART_VERSION" \
  --connect=false \
  --create-namespace

echo "==> Waiting for the vcluster control plane to be ready"
kubectl -n "$VCLUSTER_NAMESPACE" wait --for=condition=Ready "pod/${VCLUSTER_NAME}-0" --timeout=180s

echo "==> Re-applying the Vault CR so the operator picks up the now-existing"
echo "    '$VCLUSTER_NAMESPACE' namespace in caNamespaces and copies the CA secret into it"
kubectl apply -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helm/vault-cr.yaml"
sleep 5
kubectl -n "$VCLUSTER_NAMESPACE" get secret vault-tls >/dev/null 2>&1 \
  && echo "vault-tls CA secret confirmed present in $VCLUSTER_NAMESPACE" \
  || echo "WARNING: vault-tls not yet copied into $VCLUSTER_NAMESPACE - the operator may take a bit longer, check again shortly."

echo "==> Done. vcluster '$VCLUSTER_NAME' is up."
echo "Run: vcluster connect $VCLUSTER_NAME -n $VCLUSTER_NAMESPACE -- kubectl get ns   (to sanity check access)"
