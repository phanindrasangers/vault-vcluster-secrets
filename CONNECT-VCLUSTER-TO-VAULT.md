# Connecting a vcluster Pod to Host Vault — Step by Step (Helm + kubeconfig Secret)

This is the focused how-to for environments **without the `vcluster` CLI** available -
vcluster deployed via its plain Helm chart, and accessed using the kubeconfig it writes to
a Kubernetes Secret, not `vcluster connect`. For the full POC (installing Vault itself, the
webhook, architecture diagrams, every bug we hit building this), see
[README.md](README.md) - this file only covers the connection itself.

**Want this automated instead of done by hand?** Once you have a kubeconfig for the
vcluster (Step 0 below), `../scripts/setup-vault-k8s-auth.sh --target vcluster` runs Steps
1-4 for you in one command - the RBAC manifest, the auth mount config, the policy, and the
role. See the README section "Automating a new Kubernetes auth backend" for the exact
invocation. The steps below are what it's doing under the hood, useful if you want to
understand or adapt them.

## The one thing to understand before touching config

A vcluster mints its **own** service-account tokens, signed by its own control plane —
not by the host cluster. So **Vault's Kubernetes auth method must be configured against
the vcluster's own API server**, not the host's. Everything below follows from that one
fact.

## Prerequisites

- Vault running on the host, reachable at `https://vault.vault.svc.cluster.local:8200`,
  with `vault-secrets-webhook` installed in the same cluster.
- A vcluster already deployed via its Helm chart:
  ```bash
  helm repo add loft-sh https://charts.loft.sh
  helm repo update
  helm install <vcluster-name> loft-sh/vcluster \
    -n <vcluster-namespace> --create-namespace --version <chart-version>
  ```
- `kubectl` and `helm` available locally. No `vcluster` CLI needed anywhere in this guide.

Placeholders used throughout - fill in your own:

| Placeholder | Example used in this repo |
|---|---|
| `<vcluster-name>` | `demo` |
| `<vcluster-namespace>` (host namespace backing it) | `vault-demo` |
| `<auth-mount-path>` (a name you choose) | `kubernetes-vcluster-demo` |
| `<role-name>` (a name you choose) | `vcluster-demo` |
| `<sa-name>` / `<sa-namespace>` (inside the vcluster, whatever your workload uses) | `vault-reader` / `default` |
| `<vault-path>` (the Vault KV path your workload reads) | `secret/data/vcluster-demo/db` |

---

## Step 0 — Get the vcluster's kubeconfig and reach its API

Helm-installed vcluster writes an admin kubeconfig into a Secret named `vc-<vcluster-name>`
in the host namespace it's running in.

```bash
kubectl get secret vc-<vcluster-name> -n <vcluster-namespace> \
  -o jsonpath='{.data.config}' | base64 -d > /tmp/vcluster-admin-kubeconfig.yaml
chmod 600 /tmp/vcluster-admin-kubeconfig.yaml
```

**Treat this file exactly like a private key.** It contains a full client-certificate
admin identity for the vcluster (`kubernetes-super-admin`) - not a scoped token. Don't
`cat` it, don't paste its contents anywhere, don't commit it. Delete it (`shred -u` or
`rm -f`) once you're done with the one-time setup steps below - Vault itself never needs
this file; only you, running the setup commands, do.

This kubeconfig already has `server: https://localhost:8443` baked in - that's vcluster's
convention, meant to be used behind a port-forward to that exact local port. Open one in a
separate terminal (or backgrounded) and leave it running for the rest of this section:

```bash
kubectl port-forward -n <vcluster-namespace> svc/<vcluster-name> 8443:443
```

Sanity check it works:

```bash
kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml get namespaces
```

If that lists namespaces, you're talking to the vcluster.

## Step 1 — Create a scoped, durable token-reviewer ServiceAccount inside the vcluster

Without the CLI's `--service-account`/`--cluster-role` convenience flag, create the
equivalent by hand: a ServiceAccount, an RBAC binding limited to exactly the one
permission needed, and a **Secret-backed** token rather than a short-lived
`kubectl create token` one - this is the durable, non-expiring style you want for an
infrastructure integration that has to keep working indefinitely, not a token that needs
babysitting/renewal.

```bash
cat <<'EOF' | kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-tokenreview
  namespace: <sa-namespace>
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-tokenreview-token
  namespace: <sa-namespace>
  annotations:
    kubernetes.io/service-account.name: vault-tokenreview
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-tokenreview
    namespace: <sa-namespace>
EOF
```

**Why `system:auth-delegator` and nothing broader:** this is the exact, minimal permission
Kubernetes' own `TokenReview` API requires. It lets Vault ask "is this token valid, and who
does it belong to" - it does not grant read/write access to anything else in the vcluster.

**Why a `type: kubernetes.io/service-account-token` Secret instead of `kubectl create
token`:** the latter issues a token via the TokenRequest API, which is time-bound by
design (you'd have to pass a very long `--duration` and still think about renewal before it
expires). Annotating a Secret with `kubernetes.io/service-account.name` instead makes the
control plane populate `token`/`ca.crt`/`namespace` into that Secret directly, the same way
every default ServiceAccount token worked before TokenRequest existed - it does not expire
on its own, which is what you want for a long-running integration like this one. Confirmed
working against this cluster: the Secret populates its `token`/`ca.crt`/`namespace` keys
within a couple of seconds of being created.

## Step 2 — Extract the token and CA cert from that Secret

```bash
# Token - sensitive, keep it in a shell variable, never echo/print it.
TOKENREVIEW_JWT=$(kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml \
  get secret vault-tokenreview-token -n <sa-namespace> -o jsonpath='{.data.token}' | base64 -d)

# CA cert - not sensitive, safe to view/store as a normal file.
kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml \
  get secret vault-tokenreview-token -n <sa-namespace> -o jsonpath='{.data.ca\.crt}' \
  | base64 -d > /tmp/vcluster-ca.crt
```

You can now stop the port-forward from Step 0 and delete the admin kubeconfig - everything
from here on uses only the scoped token and the CA cert:

```bash
shred -u /tmp/vcluster-admin-kubeconfig.yaml 2>/dev/null || rm -f /tmp/vcluster-admin-kubeconfig.yaml
```

**Do not delete the `vault-tokenreview` ServiceAccount or its Secret** - unlike the
kubeconfig above, this one needs to keep existing permanently: Vault holds onto the token
value and re-uses it for every future login it validates. Deleting the ServiceAccount
invalidates the token immediately (Kubernetes garbage-collects the Secret's contents along
with it) and breaks the auth mount until you redo Steps 1-2 and reconfigure Vault.

## Step 3 — Enable and configure Vault's vcluster-facing auth mount

This runs directly against Vault (via `kubectl exec` into the Vault pod, since that avoids
needing local network access to Vault itself - adjust if you have a `vault` CLI configured
locally instead).

```bash
kubectl -n vault cp /tmp/vcluster-ca.crt vault-0:/tmp/vcluster-ca.crt -c vault
rm -f /tmp/vcluster-ca.crt

ROOT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.vault-root}' | base64 -d)

kubectl -n vault exec -i vault-0 -c vault -- sh -c "
export VAULT_TOKEN='$ROOT_TOKEN'
export VAULT_CACERT=/vault/tls/ca.crt
export VAULT_ADDR=https://127.0.0.1:8200

vault auth enable -path=<auth-mount-path> kubernetes

vault write auth/<auth-mount-path>/config \
  kubernetes_host=https://<vcluster-name>.<vcluster-namespace>:443 \
  kubernetes_ca_cert=@/tmp/vcluster-ca.crt \
  token_reviewer_jwt='$TOKENREVIEW_JWT'

rm -f /tmp/vcluster-ca.crt
"
```

**Important:** `kubernetes_host` here is Vault's own internal route to the vcluster - Vault
runs as a pod in the same physical cluster as the vcluster's control plane, so it reaches
it directly via the real in-cluster Service address, port 443. This has nothing to do with
the `localhost:8443` port-forward from Step 0 - that was only ever for *your* kubectl
commands to reach the vcluster from outside the cluster; Vault doesn't need it and never
sees it.

**The one line that will break this if you get it wrong:** use the **short** form
`https://<vcluster-name>.<vcluster-namespace>:443` - **not**
`https://<vcluster-name>.<vcluster-namespace>.svc.cluster.local:443`.

> vcluster's generated API server certificate only has the short hostname (and a couple of
> `*.vcluster.com` wildcards) in its SANs - never the fully-qualified `.svc.cluster.local`
> form. Using the FQDN here produces a generic `403 permission denied` on login later, with
> nothing in the error message pointing at TLS. If you ever hit that generic 403, run
> `vault monitor -log-level=debug` (from inside the Vault pod) while retrying the login -
> the debug log names the exact SAN mismatch; the client-facing error never does.

## Step 4 — Create a Vault policy and role for the workload

```bash
kubectl -n vault exec -i vault-0 -c vault -- sh -c "
export VAULT_TOKEN='$ROOT_TOKEN'
export VAULT_CACERT=/vault/tls/ca.crt
export VAULT_ADDR=https://127.0.0.1:8200

vault policy write <role-name>-read - <<'EOF'
path \"secret/data/vcluster-demo/*\" {
  capabilities = [\"read\", \"list\"]
}
EOF

vault write auth/<auth-mount-path>/role/<role-name> \
  bound_service_account_names=<sa-name> \
  bound_service_account_namespaces=<sa-namespace> \
  policies=<role-name>-read \
  ttl=1h
"
```

**Note the names you bind here:** `<sa-name>` and `<sa-namespace>` are the **plain** names
as they exist *inside* the vcluster (e.g. `vault-reader` in namespace `default`) - not any
host-side mangled name. Since the token's claims come from the vcluster's own control
plane, this is exactly what you'd expect from a normal single-cluster setup - no special
translation needed.

## Step 5 — Add the right annotations and a DNS fix to your Deployment

You'll need a working kubeconfig again to apply this - repeat the port-forward + Secret
extraction from Step 0 (or keep a separate copy of the admin kubeconfig around
specifically for ongoing deploys, stored with the same care as any other admin credential -
`chmod 600`, never committed, ideally short-lived).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default          # inside the vcluster
spec:
  template:
    metadata:
      annotations:
        vault.security.banzaicloud.io/vault-addr: "https://vault.vault.svc.cluster.local:8200"
        vault.security.banzaicloud.io/vault-role: "<role-name>"
        vault.security.banzaicloud.io/vault-path: "<auth-mount-path>"
        vault.security.banzaicloud.io/vault-skip-verify: "false"
        vault.security.banzaicloud.io/vault-tls-secret: "vault-tls"
    spec:
      serviceAccountName: <sa-name>
      hostAliases:
        - ip: "VAULT_CLUSTER_IP"      # see below - resolve at deploy time, don't hardcode
          hostnames:
            - "vault.vault.svc.cluster.local"
      containers:
        - name: my-app
          image: your-image
          env:
            - name: DB_PASSWORD
              value: "vault:<vault-path>#password"
```

Resolve the real ClusterIP right before applying (don't bake a stale IP into a tracked
file), and apply through the admin kubeconfig:

```bash
VAULT_IP=$(kubectl -n vault get svc vault -o jsonpath='{.spec.clusterIP}')
sed "s/VAULT_CLUSTER_IP/$VAULT_IP/" my-app-deployment.yaml > /tmp/my-app-rendered.yaml
kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml apply -f /tmp/my-app-rendered.yaml
rm -f /tmp/my-app-rendered.yaml
```

**Why the `hostAliases` block is required:** the vcluster's own CoreDNS has no record for
`vault.vault.svc.cluster.local` - that namespace doesn't exist in the vcluster's virtual
view, only on the host. Without this, `vault-env` (the container the webhook injects)
fails with a DNS lookup error before it ever gets to the TLS/auth steps above.

**Why `vault-tls-secret: "vault-tls"`, with no namespace override:** the webhook injects
this at admission time on the **host** (that's where the real Pod object is actually
created - vcluster syncs virtual pods down as real host Pods), so it reads the `vault-tls`
Secret from the **host's** `vault` namespace directly. No cross-boundary trick needed here -
this one just works because of where admission actually happens.

## Step 6 — Verify

```bash
kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml logs -n default deployment/my-app
```

You should see `vault-env` log `"received new Vault token"` followed by your app's own
output showing the resolved secret value. If it instead shows a DNS error, an x509 SAN
error, or a `403`, jump to the matching entry below.

When you're done, stop the port-forward and remove the admin kubeconfig file if you kept a
copy around:

```bash
shred -u /tmp/vcluster-admin-kubeconfig.yaml 2>/dev/null || rm -f /tmp/vcluster-admin-kubeconfig.yaml
```

---

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `dial tcp: lookup vault.vault.svc.cluster.local: no such host` | vcluster's CoreDNS has no record for a host namespace | Add the `hostAliases` block (Step 5) |
| `403 permission denied` on Vault login, everything else looks right | `kubernetes_host` used the FQDN instead of the short vcluster hostname | Fix `kubernetes_host` to `https://<vcluster-name>.<vcluster-namespace>:443` (Step 3); confirm with `vault monitor -log-level=debug` |
| `x509: certificate is valid for ... not <fqdn>` (visible only via `vault monitor`) | Same as above - the real error behind the generic 403 | Same fix |
| `kubectl --kubeconfig ... get namespaces` fails with a connection error | Port-forward from Step 0 isn't running, or died | Restart it: `kubectl port-forward -n <vcluster-namespace> svc/<vcluster-name> 8443:443` |
| Secret injected once but never updates after rotation | Expected - `vault-env` fetches once at container start | Add `vault-secrets-reloader` **inside the vcluster** (not on the host - see README.md "A reloader per vcluster, not one on the host"). Install it the same way: `helm install` targeted at the vcluster via `--kubeconfig /tmp/vcluster-admin-kubeconfig.yaml` instead of a `vcluster connect --` wrapper. |
| `vault-tls` / CA-related errors from a controller you installed *inside* the vcluster (not the demo workload itself) | That controller's own API calls go against the vcluster, which has no `vault` namespace | Mirror just the public `ca.crt` (never the private key) into a Secret inside the vcluster, via the same admin kubeconfig: `kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml create secret generic vault-tls -n <sa-namespace> --from-file=ca.crt=/tmp/vault-ca-only.crt` |

## A note on this repo's own scripts

`scripts/*.sh` in this repo use the `vcluster` CLI (`vcluster create`, `vcluster connect
--`) for convenience, since it's available in the environment they were built and tested
against. Every one of those CLI calls has a direct equivalent above:

| CLI command | Helm + kubeconfig equivalent |
|---|---|
| `vcluster create <name> -n <ns>` | `helm install <name> loft-sh/vcluster -n <ns> --create-namespace` |
| `vcluster connect <name> -n <ns> --service-account <sa> --cluster-role <role> --print` | Step 1 + Step 2 above (a plain ServiceAccount + `kubernetes.io/service-account-token` Secret + ClusterRoleBinding manifest, giving a durable, non-expiring token instead of the CLI's own token) |
| `vcluster connect <name> -n <ns> -- kubectl <args>` | `kubectl --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml <args>` (behind the Step 0 port-forward) |
| `vcluster connect <name> -n <ns> -- helm <args>` | `helm --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml <args>` |

Everything else - the Vault-side config, the annotations, the `hostAliases` fix, the
two-reloader architecture - is identical either way; only *how you reach the vcluster's
API* changes.
