#!/usr/bin/env bash
# Runs the full setup end to end, in the order that actually works (see README for why
# the order matters - Vault auth for the vcluster can't be configured until the vcluster
# exists, for instance).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/01-install-vault.sh"
"$SCRIPT_DIR/02-install-webhook-and-reloader.sh"
"$SCRIPT_DIR/03-create-vcluster.sh"
"$SCRIPT_DIR/04-configure-vault-auth.sh"
"$SCRIPT_DIR/05-deploy-demo.sh"
"$SCRIPT_DIR/06-install-in-vcluster-reloader.sh"

cat <<'EOF'

==> All done.

Verify the demo pod is reading the secret:
  vcluster connect demo -n vault-demo -- kubectl logs -n default deployment/vault-demo-app

Try rotating the secret and watching it reload automatically:
  ./scripts/rotate-demo-secret.sh
EOF
