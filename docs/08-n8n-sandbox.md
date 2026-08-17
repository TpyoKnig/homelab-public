# 08 · n8n sandbox service

[`n8n-sandbox-service`](https://github.com/TpyoKnig/n8n-sandbox-service) gives the n8n AI
Assistant somewhere to actually run code. Each sandbox is a Debian container managed by
an in-container Docker daemon, created and torn down over a REST API.

Without it, the assistant loads and chats but every code execution fails.

> **If you are on Talos — or any immutable-rootfs distro — use this repo at tag `0.0.1`.**
> ```
> repoURL:         https://github.com/TpyoKnig/n8n-sandbox-service.git
> targetRevision:  0.0.1
> path:            charts/n8n-sandbox-service
> ```
> That tag ships `dataPlane.mode: dind`, which is the mode to pick when you cannot modify
> the node runtime. The chart's default `sysbox` mode cannot work there at all — see
> [Why `dind` mode on Talos](#why-dind-mode-on-talos). (`external` mode installs on Talos
> too, but it deploys only the API and expects the runner to run outside the chart, so it
> moves the problem off-cluster rather than solving it here.)

Pinned at the git tag **`0.0.1`** (commit `3a52ff8`), whose vendored chart declares
`version: 0.3.0`, `appVersion: 0.1.0`. The chart is **not published to a registry** —
reference the tag or the commit to get this exact copy. Deployed in `dind` mode, which
exists for exactly this kind of cluster.

## Shape

```
n8n-main ──X-Api-Key──> sandbox-api ──gRPC + mTLS──> runner (DinD) ──> sandbox containers
                        :8080 http                    :8080 http
                        :9090 grpc (registration)     :9091 grpc (control)
```

| Component | Role |
| --- | --- |
| API `Deployment` | Public HTTP API, runner registration, sandbox routing state |
| Runner `StatefulSet` | Owns sandbox lifecycles via an inner Docker daemon |
| sandbox containers | One per session, from a configurable Debian image |

The runner is a **StatefulSet behind a headless Service** on purpose: the API must call
the *specific* runner that owns a sandbox, so a load-balanced Service is not enough for
exec/files/control. Stable pod DNS also makes the runner control certificate's SANs
practical. **If a runner dies, sandboxes on it should be treated as lost.**

## Why `dind` mode on Talos

The chart offers three data-plane modes:

| Mode | Runner | Isolation from the node |
| --- | --- | --- |
| `sysbox` | in-cluster, `runtimeClassName: sysbox-runc` | user-namespaced by the sysbox runtime |
| `dind` | in-cluster, privileged Docker-in-Docker | container capabilities only |
| `external` | outside Kubernetes | n/a — only the API is rendered |

**`sysbox` is the default and the stronger of the two. Prefer it wherever the node runtime
can be changed.** It is not an option here: installing sysbox means writing the node's
containerd configuration and restarting kubelet, and Talos has no shell, no package
manager and a read-only `/`. The installer cannot run at all. Flatcar and Fedora CoreOS
are the same story; GKE Autopilot blocks privileged containers, so *neither* mode works
there.

On such a cluster `sysbox` is not slower or harder, it is **unavailable** — the
`sysbox-runc` RuntimeClass never exists and the runner pod stays `Pending` forever with no
obvious cause.

**What `dind` gives up, stated plainly:** sysbox runs the runner inside a user namespace,
so the inner Docker daemon never holds real privileges on the node. `dind` takes those
capabilities from the kernel directly, and a privileged container can see the node's
cgroup tree and its devices. That is defensible for a namespace running code you already
control — including AI-generated code from your own instance. It is **not** defensible for
a shared or multi-tenant cluster. If you need that boundary and cannot run sysbox, the
honest answer is a separate cluster or a node pool you're willing to treat as compromised,
not this mode with extra settings.

Both in-cluster modes run the same runner image and share the whole config, TLS and
service surface; they differ only in where the container gets its privileges. The chart
**fails at render time** rather than producing a pod that starts and then cannot run a
sandbox — `dind` without `privileged`, `dind` naming a `runtimeClassName`, and `sysbox`
with `privileged` are each rejected at install.

The `dind` path is verified end to end on Talos v1.13.7 / Kubernetes v1.36.3, which is
this lab's exact configuration.

## Install

Manifests: [`iac/argocd/app-n8n-sandbox.yaml`](../iac/argocd/app-n8n-sandbox.yaml) and
[`iac/apps/n8n-sandbox/values.yaml`](../iac/apps/n8n-sandbox/values.yaml).

### 1. The namespace must permit privileged pods

```bash
kubectl create namespace n8n-sandbox
kubectl label namespace n8n-sandbox \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
```

`enforce` is the one that matters; `warn` and `audit` just keep the install output
readable. **Skip this and the symptom is that no runner pod is ever created and nothing
obviously errors** — Pod Security Admission puts the denial on the StatefulSet as an event,
not on a pod.

### 2. Auth Secret

Four keys in one Secret. **`runner-api-key` and `runner-api-keys` must hold the same
value** — the API presents the first when calling a runner, and the runner accepts the
second.

```bash
RUNNER_KEY=$(openssl rand -hex 24)

kubectl -n n8n-sandbox create secret generic sandbox-auth \
  --from-literal=api-keys="$(openssl rand -hex 24)" \
  --from-literal=runner-registration-token="$(openssl rand -hex 24)" \
  --from-literal=runner-api-key="$RUNNER_KEY" \
  --from-literal=runner-api-keys="$RUNNER_KEY"
```

The chart's `auth.generated.*` path works too but puts the values in the Helm release.
Prefer the Secret. (It refuses to render on an empty or `changeme` generated value, so it
will not let you expose the API with placeholder credentials.)

In this cluster, deliver that Secret as a `SopsSecret` like every other credential — see
[05-gitops](05-gitops.md#secrets-sops--age--sops-secrets-operator).

### 3. mTLS certificates

The API and runner authenticate to each other with mTLS. The chart's default
`tls.mode: existingSecret` expects **four** TLS Secrets it does not create; left unset,
both pods sit in `ContainerCreating` waiting for volumes that never appear.

`tls.mode: certManager` renders all four `Certificate` resources instead. cert-manager is
already in this cluster ([03-platform-layer](03-platform-layer.md#cert-manager)), so this
is a private CA issuer plus one value:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: sandbox-selfsigned, namespace: n8n-sandbox }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: sandbox-ca, namespace: n8n-sandbox }
spec:
  isCA: true
  commonName: n8n-sandbox-ca
  secretName: sandbox-ca
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: sandbox-selfsigned, kind: Issuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: sandbox-ca, namespace: n8n-sandbox }
spec:
  ca: { secretName: sandbox-ca }
```

**This is a separate, private CA — not `letsencrypt-prod`.** These certificates are for
in-cluster mTLS between two workloads; a public ACME issuer is the wrong tool and would
mean nothing here.

The four certificates are: API registration server (`server auth`), API control client
(`client auth`), runner registration client (`client auth`), runner control server
(`server auth`). The chart fills in the Service DNS names, including a wildcard pod DNS
name for the StatefulSet runners.

### 4. The chart

No node labels, no tolerations, no RuntimeClass. Any node that can run a privileged pod
can run this.

**The chart is not published to any registry.** It is vendored in the service repo and
distributed by git tag only — there is no Helm repo and no OCI artifact to `helm repo add`
or pull from. `0.3.0` is the version string inside `Chart.yaml`; the thing you actually
reference is the **tag `0.0.1`** (commit `3a52ff8`). Pin the tag, not the chart version.

```bash
git clone --depth 1 --branch 0.0.1 https://github.com/TpyoKnig/n8n-sandbox-service.git
helm upgrade --install n8n-sandbox-service \
  ./n8n-sandbox-service/charts/n8n-sandbox-service \
  --namespace n8n-sandbox \
  -f iac/apps/n8n-sandbox/values.yaml
```

The Argo Application takes the same route — `repoURL` + `path: charts/n8n-sandbox-service`
+ `targetRevision: "0.0.1"` — for exactly this reason. If a registry-published chart ever
appears, swapping `sources[0]` to an `oci://` reference is the only change needed.

> **Name the release after the chart.** The chart's `fullname` helper is the standard one:
> `<release>-<chart>`, collapsed to just `<release>` when the release name already contains
> the chart name. Installing as release `n8n-sandbox` against chart `n8n-sandbox-service`
> therefore yields `n8n-sandbox-n8n-sandbox-service-api` — which is what the upstream
> quickstart shows. Release `n8n-sandbox-service` collapses it to `n8n-sandbox-service-api`,
> which is the name used throughout this repo. `fullnameOverride: sandbox` is the shorter
> alternative if you prefer `sandbox-api`.
>
> Whatever you pick, `N8N_SANDBOX_SERVICE_URL` has to match it.

## Verify

```bash
kubectl -n n8n-sandbox get pods
kubectl -n n8n-sandbox logs deploy/n8n-sandbox-service-api | grep 'runner registered'
```

A registered runner reports its capacity. **That a runner started is not evidence that it
works** — create a sandbox and run something in it:

```bash
KEY=$(kubectl -n n8n-sandbox get secret sandbox-auth \
      -o jsonpath='{.data.api-keys}' | base64 -d | cut -d, -f1)
API=n8n-sandbox-service-api

ID=$(kubectl -n n8n-sandbox exec deploy/$API -- \
  wget -qO- --header "X-Api-Key: $KEY" --header 'Content-Type: application/json' \
  --post-data '{}' http://localhost:8080/sandboxes | sed 's/.*"id":"\([^"]*\)".*/\1/')

kubectl -n n8n-sandbox exec deploy/$API -- \
  wget -qO- --header "X-Api-Key: $KEY" --header 'Content-Type: application/json' \
  --post-data '{"command":"echo ok"}' "http://localhost:8080/sandboxes/$ID/executions"
```

The second call streams NDJSON ending in an `exit` event with `"success":true`.

## Wiring n8n to it

In the n8n Terraform root (see [07-n8n](07-n8n.md)):

```hcl
{ name = "N8N_INSTANCE_AI_SANDBOX_ENABLED",  value = "true" }
{ name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" }
{ name = "N8N_SANDBOX_SERVICE_URL",          value = "http://n8n-sandbox-service-api.n8n-sandbox.svc.cluster.local:8080" }
```

plus `N8N_SANDBOX_SERVICE_API_KEY` from a Secret, holding one of the values in the
service's `api-keys` list.

**The variable names are `N8N_SANDBOX_SERVICE_URL` and `N8N_SANDBOX_SERVICE_API_KEY`.**
n8n's own documentation names `N8N_INSTANCE_AI_SANDBOX_API_URL` and
`N8N_INSTANCE_AI_SANDBOX_API_KEY`; those strings appear in no shipped build. n8n does not
error on an environment variable it never reads, so the documented spelling gives you an
assistant that loads and cannot execute anything, silently. Verified by grepping the
running bundle.

**The URL and the key move together.** Rotate one without the other and the editor and
assistant chat keep working while only code execution breaks — which reads as a sandbox
outage rather than a credential mismatch, and sends you debugging the wrong component.

## Operational notes

**Storage.** The inner Docker daemon writes image layers to `/var/lib/docker`. Sysbox
would give the container its own; in `dind` mode the chart mounts an `emptyDir` capped by
`dindRunner.dockerDataRoot.emptyDirSizeLimit` (20 Gi default — deliberately not tiny, the
sandbox image alone is most of a gigabyte, and an evicted pod takes every running sandbox
with it). Set `dindRunner.dockerDataRoot.persistence.enabled=true` for a
`volumeClaimTemplate` instead: survives a restart and skips re-pulling the sandbox image,
at the cost of a PVC per replica. Never share one `/var/lib/docker` across runner pods —
dockerd requires exclusive access to its graph.

**API state.** SQLite by default, with `api.persistence.enabled` on so sandbox routing
survives a restart. Keep `api.replicaCount: 1` on SQLite. Multi-pod means Postgres via
`api.config.store=postgres` and `SANDBOX_API_POSTGRES_*` env — and CNPG is already here if
you want it.

**Metrics.** The API and runner expose `/metrics` on their HTTP ports. The chart's
`ServiceMonitor` needs the Prometheus Operator CRD, which this cluster does not run —
leave `monitoring.serviceMonitor.enabled: false` and scrape via the API-server-proxy
pattern like everything else ([06-ops-host](06-ops-host.md#scraping-the-cluster-from-outside)).

**NetworkPolicy** is off by default. Worth enabling here: restrict the API's HTTP port to
the n8n namespace, since nothing else should be creating sandboxes.

**Chart 0.3.0 renamed two keys** (`networkPolicy.sysboxRunner.ingressFrom` →
`networkPolicy.runner.ingressFrom`, and the matching `monitoring.serviceMonitor.*`). The
old names are *rejected* at render rather than ignored, so an upgrade carrying either
fails loudly instead of quietly changing behaviour.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| No runner pod, no error | Missing privileged namespace label. `kubectl -n n8n-sandbox describe statefulset` shows the PodSecurity event |
| `dockerd` exits immediately | Container did not get privileged. Check `.spec.containers[0].securityContext` |
| Runner pod stays `Pending` | A leftover sysbox `nodeSelector` or toleration. `dindRunner.scheduling` defaults to empty for this reason |
| Pods stuck `ContainerCreating` | A missing Secret — kubelet blocks on the volume rather than reporting a config error. Expect `sandbox-auth` plus the four TLS Secrets; `kubectl get certificate` shows `READY: False` with a reason |
| `operation not permitted` dialing the API, at runner startup | **Expected, and self-clearing.** The runner comes up before its inner Docker daemon finishes networking, so early registration attempts back off. Only worry if `runner registered` never appears in the API log |
