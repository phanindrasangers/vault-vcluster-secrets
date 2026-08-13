# Vault (bank-vaults) + vcluster: consuming host secrets from inside a virtual cluster

A pod running **inside a vcluster** consumes a KV secret stored in the **host cluster's**
Vault, injected by bank-vaults' mutating webhook, with automatic pod restarts when the
secret rotates. Everything in this repo has been deployed and verified end to end on a
real cluster (see [What we verified](#what-we-verified)) - including two real bugs and one
non-obvious architectural fact discovered along the way, all documented below because
they're exactly the things that will bite you if you build this yourself without hitting
them first.

**Just want the connection steps, not the full install?** See
[CONNECT-VCLUSTER-TO-VAULT.md](CONNECT-VCLUSTER-TO-VAULT.md) for a focused, config-by-config
walkthrough of wiring a vcluster workload up to an already-running host Vault, or run
`scripts/setup-vault-k8s-auth.sh` to automate that whole walkthrough (RBAC, auth mount,
policy, role) in one command - see [scripts/setup-vault-k8s-auth.sh](#automating-a-new-kubernetes-auth-backend) below.

This is a POC, not a production design. Single-node Vault, no HA, a demo secret seeded in
plaintext in a tracked file. See [Hardening before production](#hardening-before-anything-beyond-a-poc).

## The one fact that shapes this whole design

**A vcluster mints its own service account tokens - they are not signed by the host
cluster.** We confirmed this by inspecting a running pod's projected token volume: instead
of the normal kubelet-managed token, vcluster injects a token via a `downwardAPI` volume
reading a pod annotation (`vcluster.loft.sh/token-...`) that it generates itself, signed by
the **vcluster's own** control plane.

The practical consequence: **Vault's Kubernetes auth method must be configured against the
vcluster's own API server, not the host's**, in order to validate tokens presented by pods
running inside it. This is the opposite of what you'd assume for "a pod in a Kubernetes
cluster talking to Vault," and it's why this repo has two separate Kubernetes auth mounts
in Vault (see below) instead of one.

## Architecture

```mermaid
flowchart TB
    subgraph Host["Host cluster"]
        subgraph vaultns["vault namespace"]
            VaultOp[vault-operator] --> Vault[(Vault\nRaft storage)]
            Webhook[vault-secrets-webhook]
            ReloaderHost[vault-secrets-reloader\n(host instance)]
        end
        subgraph vdns["vault-demo namespace"]
            VclusterCP[vcluster control plane\nService: demo.vault-demo:443]
            RealPod["Real Pod\n(synced from vcluster)"]
        end
        Webhook -.mutates at admission.-> RealPod
        ReloaderHost -."can only see host\nDeployments - not this one".-x RealPod
    end
    subgraph Vcluster["Inside the 'demo' vcluster (virtual)"]
        VDeploy[Deployment: vault-demo-app]
        ReloaderV[vault-secrets-reloader\n(in-vcluster instance)]
        VDeploy -.same object, synced.-> RealPod
        ReloaderV -->|watches| VDeploy
        ReloaderV -->|auth via kubernetes-vcluster-demo mount| Vault
    end
    RealPod -->|vault-env init container\nauth via kubernetes-vcluster-demo mount| Vault
    VclusterCP -->|TokenReview validates\nvcluster-signed tokens| Vault
```

Two Kubernetes auth mounts in Vault, on purpose:

| Mount path | Validates tokens from | Used by |
|---|---|---|
| `kubernetes` | The **host** cluster's API (`kubernetes.default.svc`) | `vault-secrets-reloader` running on the host - it's a host-native pod with a normal host-issued token |
| `kubernetes-vcluster-demo` | The **vcluster's** own API (`demo.vault-demo:443`) | The demo workload, and a second `vault-secrets-reloader` instance running *inside* the vcluster |

## Prerequisites

- `kubectl`, `helm` v3
- `vcluster` CLI (tested with v0.35.1) - this repo pins the vcluster Helm chart to that
  version to match what's already used elsewhere in this environment
- Docker reachable locally (the vcluster CLI uses it for a background connection proxy)
- Cluster-admin or equivalent

## Repo layout

```
helm/
  vault-rbac.yaml                              RBAC for the Vault CR's own ServiceAccount
  vault-cr.yaml                                The Vault custom resource (KV engine, demo secret, TLS)
  values-vault-secrets-webhook.yaml
  values-vault-secrets-reloader.yaml            Host-side reloader instance
  values-vault-secrets-reloader-in-vcluster.yaml  In-vcluster reloader instance
examples/
  demo-deployment.yaml                          Applied INSIDE the vcluster - the actual demo workload
vcluster/
  demo-vcluster-ca.crt                          Public CA cert of the demo vcluster (not sensitive - kept for reference)
scripts/
  install.sh                                    Runs everything below, in order
  01-install-vault.sh
  02-install-webhook-and-reloader.sh
  03-create-vcluster.sh
  04-configure-vault-auth.sh
  05-deploy-demo.sh
  06-install-in-vcluster-reloader.sh
  rotate-demo-secret.sh                         Rotates the secret and watches it auto-reload
  setup-vault-k8s-auth.sh                       Automates wiring up a NEW auth backend (host or vcluster) - see below
```

## Install

```bash
./scripts/install.sh
```

This runs, **in this exact order** (order matters - see the next section):

1. `vault-operator` + Vault CR (namespace `vault`) - Vault comes up auto-initialized, auto-unsealed, with KV v2 mounted at `secret/`, a demo secret at `secret/data/vcluster-demo/db`, and the host-facing `kubernetes` auth mount configured.
2. `vault-secrets-webhook` + a host-side `vault-secrets-reloader`.
3. The `demo` vcluster (namespace `vault-demo`).
4. Vault's vcluster-facing `kubernetes-vcluster-demo` auth mount - only possible now that the vcluster exists.
5. The demo workload, applied *inside* the vcluster.
6. A second `vault-secrets-reloader`, also applied *inside* the vcluster.

### Why Vault auth is configured after the vcluster exists

Vault's Kubernetes auth config needs the vcluster's API address, its CA certificate, and a
token-reviewer credential minted *from inside it* - none of which exist until the vcluster
itself has been created. This is why the auth mount is configured imperatively in step 4,
not declared upfront in the Vault CR alongside the KV engine and demo secret (which have no
such dependency and are fully declarative in `helm/vault-cr.yaml`).

## Automating a new Kubernetes auth backend

`scripts/setup-vault-k8s-auth.sh` does everything in steps 4/6 above (and everything in
`CONNECT-VCLUSTER-TO-VAULT.md`) in one command, for either target:

```bash
# Host cluster: add a role for another host-side workload to the existing "kubernetes" mount
./scripts/setup-vault-k8s-auth.sh --target host \
  --role-name my-app --bound-sa-name my-app --bound-sa-namespace default \
  --path-glob 'my-app/*'

# vcluster: wire up a brand-new vcluster end to end (RBAC + auth mount + policy + role)
./scripts/setup-vault-k8s-auth.sh --target vcluster \
  --kubeconfig /tmp/vcluster-admin-kubeconfig.yaml \
  --kubernetes-host https://demo.vault-demo:443 \
  --auth-path kubernetes-demo \
  --role-name demo-app --bound-sa-name vault-reader --bound-sa-namespace default \
  --path-glob 'demo-app/*'
```

For `--target vcluster` it creates the durable ServiceAccount + `kubernetes.io/service-account-token`
Secret + `system:auth-delegator` ClusterRoleBinding itself (the same manifest from
`CONNECT-VCLUSTER-TO-VAULT.md` Steps 1-2) - nothing to apply by hand first. For `--target host`
it skips RBAC entirely and reuses Vault's own pod identity, which already has
`system:auth-delegator` via `helm/vault-rbac.yaml`. Either way it finishes by writing a
policy (full access to a KV path glob you choose - narrow `--path-glob` for anything beyond
a demo) and a role bound to your workload's ServiceAccount, so the only thing left to do is
annotate the Deployment with `vault.security.banzaicloud.io/*` (see
`examples/demo-deployment.yaml`) and point it at the role/path the script printed. Run it
with `--help` for the full flag reference. Verified against this repo's own `vault` and
`demo` vcluster: a login with the created role returned exactly the policy the script wrote,
nothing more.

## The two real gotchas we hit building this

Both are documented inline in the scripts too, but here's the full story:

**1. DNS: the vcluster's CoreDNS can't resolve host Service names.** A pod inside the
vcluster resolving `vault.vault.svc.cluster.local` gets NXDOMAIN - that namespace doesn't
exist in the vcluster's own (virtual) view, and vcluster 0.35.1 has no built-in mechanism
to sync arbitrary host Services into a vcluster's DNS. The fix: a `hostAliases` entry in
the pod spec pinning that exact hostname to Vault's ClusterIP, so the name still resolves
(and still matches Vault's server cert SAN, so TLS verification stays intact) without
touching CoreDNS. The tradeoff: that ClusterIP isn't guaranteed stable if the `vault`
Service is ever deleted and recreated - `scripts/05-deploy-demo.sh` and
`06-install-in-vcluster-reloader.sh` both re-read it fresh at deploy time, so a re-run
picks up a changed IP; a long-running pod would not.

**2. TLS: use the short hostname, not the FQDN, for `kubernetes_host`.** When configuring
Vault's vcluster-facing auth mount, we first pointed `kubernetes_host` at
`https://demo.vault-demo.svc.cluster.local:443` and got a confusing generic `403 permission
denied` on login - with no indication of why. Vault's debug logs (`vault monitor
-log-level=debug`) revealed the real error: `x509: certificate is valid for ... demo,
demo.vault-demo, ..., not demo.vault-demo.svc.cluster.local`. vcluster's generated API
server certificate SANs only include the short forms (`demo`, `demo.vault-demo`) plus a
couple of `*.vcluster.com` wildcards - never the fully-qualified `.svc.cluster.local` name.
Using `https://demo.vault-demo:443` fixed it immediately. If you ever see a generic 403 on
a Vault Kubernetes-auth login with everything else (RBAC, reachability, role binding)
looking correct, check this first via `vault monitor` before assuming it's a permissions
problem - we spent real time down that path (adding unnecessary RBAC) before finding the
actual cause.

## A reloader per vcluster, not one on the host

`vault-secrets-reloader` watches Deployments/StatefulSets/DaemonSets and rolls them when a
referenced Vault secret gets a new version. vcluster does **not** sync those controller
objects to the host - only the Pods they produce end up there (with mangled names, as real
host Pods). A reloader running on the host, watching the host's own Deployments API, will
therefore never see `default/vault-demo-app` - it only exists inside the vcluster's own API
server. We confirmed this directly: the host-side reloader logged "No workloads to reload"
indefinitely despite the demo Deployment carrying the correct opt-in annotation, while a
second instance installed *inside* the vcluster immediately logged `Collected secrets from
Deployment default/vault-demo-app` and, after a rotation, `Reloading workload: {vault-demo-app
default Deployment}`.

Practical upshot: **every vcluster that has Vault-consuming workloads needs its own
`vault-secrets-reloader` instance**, authenticating through that vcluster's own Vault auth
mount (`06-install-in-vcluster-reloader.sh`). The host-side instance
(`02-install-webhook-and-reloader.sh`) is still worth having for anything running directly
on the host, outside any vcluster.

The in-vcluster reloader hits the same DNS gotcha as the demo workload (same `hostAliases`
fix) plus one more: its own `VAULT_TLS_SECRET`/`VAULT_TLS_SECRET_NS` lookup is a live API
call against whatever cluster it's running in - the vcluster, in this case - so the real
`vault-tls` Secret (which lives on the host, in the `vault` namespace) isn't visible to it
either. The fix is to mirror **only the public CA certificate** (never the private key)
into a Secret named `vault-tls` inside the vcluster's own `default` namespace -
`06-install-in-vcluster-reloader.sh` does this with a single `kubectl get secret ... | base64
-d` of the `ca.crt` key, nothing else.

## Verify it yourself

```bash
# See the secret injected into the running pod
vcluster connect demo -n vault-demo -- kubectl logs -n default deployment/vault-demo-app

# Rotate it and watch the pod restart automatically with the new value
./scripts/rotate-demo-secret.sh "some-new-password"
```

## What we verified

This was built and tested against a real Kubernetes cluster (kind), not written and
assumed to work:

- `vault-operator` 1.24.0, `vault-secrets-webhook` 1.23.1, and `vault-secrets-reloader`
  0.5.0 - all bank-vaults' current OCI Helm charts - install cleanly and reach `Running`.
- Vault auto-initializes, auto-unseals, and applies the CR's `externalConfig` (KV v2 engine,
  policy, demo secret) with zero manual steps - confirmed by reading the seeded secret back
  via `vault kv get` from inside the Vault pod.
- The vcluster's fake-token architecture was confirmed by inspecting a running pod's
  projected-token volume definition directly, not assumed from documentation.
- A direct, manual `TokenReview` call against the vcluster's API (bypassing Vault) was used
  to isolate the SAN-mismatch bug from an RBAC problem before concluding what the real fix
  was - the manual call succeeded with `authenticated: true` well before the Vault-side
  login did, which is what pointed at Vault's own request (not the underlying auth
  mechanism) as the problem.
- End-to-end secret consumption: a pod inside the vcluster logged the exact seeded
  `username`/`password` pulled live from the host's Vault.
- End-to-end rotation: the secret was rewritten in Vault (`vault kv put`, version 2, then
  version 3), and the in-vcluster `vault-secrets-reloader` was observed detecting the new
  version and logging `Reloading workload: {vault-demo-app default Deployment}`, after which
  the newly-created pod's logs showed the rotated value.
- `vault-secrets-reloader` chart v0.5.0 has a real template bug: setting `volumes` or
  `volumeMounts` in its values renders invalid YAML (missing the parent key). Worked around
  by not setting them at all - the controller's ClusterRole only grants `get` on Secrets, so
  it reads `VAULT_TLS_SECRET` via the Kubernetes API directly and never needed a mounted
  volume in the first place.

## Data handling note

`helm/vault-cr.yaml` seeds a demo secret (`S3cr3t-From-Host-Vault!`) directly in a tracked
file for this POC to be self-contained and easy to verify. Don't do this for anything real -
use `startupSecrets` only for synthetic/demo values, and write real secrets into Vault via
`vault kv put` (or a proper secrets pipeline) after the fact, never committed to a repo. Per
Improving's data handling policy, no client-confidential data or real credentials belong in
this pipeline without a confirmed DPA regardless.

## Hardening before anything beyond a POC

- `size: 1` single-node Vault with Raft storage in `vault-cr.yaml` has no HA. Bump to 3+
  replicas for anything real.
- The root token is stored in the `vault-unseal-keys` Secret and used directly in the setup
  scripts. Fine for a test environment; create scoped, time-limited tokens for anything
  beyond that, per Vault's own guidance printed in its unseal-keys secret.
- The `hostAliases` IP-pinning approach for cross-vcluster DNS is a POC-grade workaround. If
  you're doing this for real, look at whether a newer vcluster version supports syncing
  host Services into the vcluster's DNS view (0.35.1, used here, does not).
- `vault-secrets-reloader`'s poll intervals are shortened to 30s/1m in this repo purely so
  the rotation demo is observable in a single sitting. Put them back to sane defaults
  (`collectorSyncPeriod: 30m`, `reloaderRunPeriod: 1h`) for anything beyond a demo, to keep
  polling load on Vault reasonable.
- TLS is enabled throughout (Vault's listener, the webhook's admission server) - keep it
  that way; don't reach for `vault-skip-verify: "true"` to route around DNS/cert issues the
  way it might be tempting to after reading the gotchas above. Fix the hostname/SAN instead,
  as this repo does.

## Troubleshooting

**Generic `403 permission denied` on a Vault Kubernetes-auth login, everything else looks
right:** run `vault monitor -log-level=debug` (from inside the Vault pod, or via `vault
monitor` against `VAULT_ADDR`) while retrying the login. The client-facing error is
deliberately generic; the debug log shows the real underlying reason. Check for a
certificate SAN mismatch first (see gotcha #2 above) - it produces exactly this generic
error and is easy to mistake for an RBAC problem.

**A pod inside the vcluster can't reach Vault by name:** check whether it's resolving a
host-cluster DNS name (like `vault.vault.svc.cluster.local`) from inside the vcluster's own
CoreDNS - it won't find it. Either add a `hostAliases` entry (see gotcha #1) or point at
Vault's ClusterIP directly (breaks TLS verification unless the IP happens to be a cert SAN,
which it normally isn't).

**`vault-secrets-reloader` never reloads anything, despite the workload having the right
annotation:** check which cluster it's actually watching. If the workload's Deployment
object lives inside a vcluster, a host-side reloader instance cannot see it - you need an
instance running inside that vcluster (see "A reloader per vcluster" above).

**vault-secrets-reloader Helm install fails with a YAML parse error mentioning `deployment.yaml`:**
you probably set `volumes` or `volumeMounts` in its values - chart v0.5.0 has a template bug
there. Don't set them; the controller doesn't need them (see "What we verified").
