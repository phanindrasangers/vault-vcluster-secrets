#!/usr/bin/env bash
# Deploys the demo workload INSIDE the vcluster. Renders demo-deployment.yaml's
# hostAliases placeholder with Vault's actual ClusterIP first - see README "Why
# hostAliases" for why the vcluster's own CoreDNS can't resolve a host Service by name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VCLUSTER_NAME="demo"
VCLUSTER_NAMESPACE="vault-demo"

VAULT_IP=$(kubectl -n vault get svc vault -o jsonpath='{.spec.clusterIP}')
echo "==> Rendering demo-deployment.yaml with Vault ClusterIP $VAULT_IP"
sed "s/VAULT_CLUSTER_IP_PLACEHOLDER/$VAULT_IP/" "$ROOT_DIR/examples/demo-deployment.yaml" > /tmp/demo-deployment-rendered.yaml

echo "==> Applying inside the vcluster"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl apply -f /tmp/demo-deployment-rendered.yaml
rm -f /tmp/demo-deployment-rendered.yaml

echo "==> Waiting for the demo pod to become ready"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl rollout status deployment/vault-demo-app -n default --timeout=120s

echo "==> Logs (should show DB_USERNAME/DB_PASSWORD pulled live from Vault):"
vcluster connect "$VCLUSTER_NAME" -n "$VCLUSTER_NAMESPACE" -- \
  kubectl logs -n default deployment/vault-demo-app --tail=10
