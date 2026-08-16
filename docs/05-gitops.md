# 05 · GitOps — Forgejo + Argo CD + SOPS

Every cluster workload is reconciled from git. The git server itself runs **off** the
cluster, on the Pi, behind its own Cloudflare tunnel.

```
   workstation                            pi-ops (192.168.1.100)
       │                                   ┌──────────────────────┐
   sops -e -i                              │ /opt/git/  Forgejo   │  :3001 LAN, :222 SSH
   git push ────── git.example.com ───────>│ /opt/obs/  Prom/Loki │
                    (pi-ops tunnel)        │ cloudflared          │
                                           └──────────┬───────────┘
   cluster (Talos, 3 nodes)                           │ LAN pull
       ├── Argo CD @ gitops.example.com ──────────────┘
       ├── sops-secrets-operator  (SopsSecret → native Secret, via age key)
       └── every workload reconciled from git
```

**The isolation is the point.** If the cluster is gone — completely gone —
`git.example.com` still serves the source of truth. Rebuild the cluster, run one
bootstrap script, and Argo pulls everything back.

## Repo layout

```
homelab-gitops/
├── .sops.yaml               age recipient + creation rules (public key only)
├── bootstrap/               root Application + one Application per app
│   ├── root-app.yaml           watches bootstrap/ recursively; self-registers everything
│   ├── infra-cert-manager.yaml
│   └── …
├── infra/                   Helm values + raw manifests for cluster plumbing
│   ├── cert-manager/values.yaml
│   ├── longhorn/values.yaml
│   └── …
├── apps/                    workload Applications
├── secrets/                 standalone SopsSecrets
└── scripts/bootstrap.sh     idempotent cold-start recovery
```

## The Application pattern

Two sources: chart from upstream, values from git. No fork, no vendored chart, no wrapper.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: cert-manager }
  sources:
    - repoURL: https://charts.jetstack.io
      chart: cert-manager
      targetRevision: v1.16.5
      helm:
        releaseName: cert-manager
        valueFiles: [$values/infra/cert-manager/values.yaml]
    - repoURL: http://192.168.1.100:3001/<user>/homelab-gitops.git
      targetRevision: main
      ref: values                    # ← this is what makes $values resolve above
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Bump a chart by editing `targetRevision`. Tune config by editing the values file.

> **Keep it to two sources.** Combining `chart` + `ref: values` + a `path:` for raw
> manifests in one Application is intermittently unreliable — the values-ref gRPC call to
> the repo-server fails under load. For workloads that also need raw manifests
> (SopsSecrets, extra Services), split into two Applications: `<name>` for the chart and
> `<name>-secrets` as a single-source `path:`. One extra Application, much less flakiness.

## Secrets: SOPS + age + sops-secrets-operator

One age keypair covers the repo. The public key is committed in `.sops.yaml`; the private
key lives in a password manager and in `~/.config/sops/age/keys.txt`
(`%APPDATA%\sops\age\keys.txt` on Windows).

```bash
sops secrets/my-thing.sops.yaml    # opens $EDITOR with plaintext, re-encrypts on save
git commit -am "rotate thing" && git push
```

The `.sops.yaml` creation rules encrypt only `data` and `stringData`, so `name`,
`namespace` and `kind` stay readable and `git diff` remains meaningful.

In-cluster, `sops-secrets-operator` mounts the age key, watches `SopsSecret` CRDs and
reconciles them into native `Secret`s. From a Deployment's point of view nothing is
unusual — it references `Secret/foo` as always.

**Chosen over External Secrets + a vault Connect server** because files stay editable
offline and there is no extra pod in the path. **Chosen over KSOPS** because it needs no
repo-server sidecar and no plugin config, and works with any GitOps tool. The trade-off
is that it only handles Secrets — which is exactly the surface needed.

## Cold start from git

Assumes the cluster is gone or beyond `kubectl apply`.

1. Rebuild the cluster: [BOOTSTRAP.md](../BOOTSTRAP.md) stages A–H (Talos, Cilium,
   Longhorn, cert-manager, ingress-nginx). This is the minimum Argo cannot do for itself.
2. Restore the age private key to `~/.config/sops/age/keys.txt`.
3. Restore the Forgejo PAT: `export FORGEJO_TOKEN=…`.
4. `git clone https://git.example.com/<user>/homelab-gitops.git && cd homelab-gitops`
5. `./scripts/bootstrap.sh` — installs Argo CD and sops-secrets-operator, seeds the age
   key and the repo credential, applies `bootstrap/root-app.yaml`.
6. `kubectl -n argocd get apps -w` — everything self-syncs.

Initial Argo password:
`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## Gotchas worth having read first

**Repo-server memory.** The chart default `repoServer.resources.limits.memory: 512Mi`
OOMs during `helm pull` of larger charts. The container exits 137, the pod
`CrashLoopBackOff`s, `Service/argocd-repo-server` has zero healthy backends, and the
app-controller then fails with `dial tcp <svc-ip>:8081: connect: operation not permitted`
— an `EPERM` that reads exactly like a NetworkPolicy problem and is not. There are simply
no listeners. Pin `requests: {cpu: 50m, memory: 512Mi}, limits: {memory: 2Gi}`.

**`ServerSideApply=true` is essential when adopting existing resources.** Client-side
apply rewrites the whole object and clashes with Helm's annotations; SSA merges only the
fields Argo manages.

**SopsSecret over a pre-existing plain Secret** fails with *"Child secret is not owned by
controller"* — the operator refuses to steal ownership. `kubectl delete secret <name>`
once; it is recreated in about two seconds with a proper owner reference. Only bites
during migration.

**Old Helm release metadata survives adoption.** `helm ls -A` keeps showing the pre-Argo
releases. Do **not** `helm uninstall` — that deletes the resources Argo now owns. Ignore
them.

**Chart-rendered resources that cause eternal drift.** Two recurring shapes:
- *Duplicate env vars* — a chart that derives `SOME_URL` from its ingress config, plus the
  same name restated in `extraEnv`, renders two entries with the same key. Legal YAML,
  illegal for structured-merge diff. Don't restate chart-derived env vars.
- *`kubectl.kubernetes.io/last-applied-configuration` on chart-rendered CRs.* Some charts
  emit this legacy annotation on `ServiceMonitor`/`PodMonitor`. Argo's SSA won't remove
  it and re-applying re-adds it. `ignoreDifferences` on the annotation path is flaky. If
  the resource is unused anyway — no Prometheus Operator here — the real fix is
  `serviceMonitor.enabled: false`.

**Hand-written StatefulSets drift on kube-defaulted fields**, and that stalls the root
app's sync-wave chain. Kubernetes auto-populates a dozen fields
(`ports[].protocol`, `terminationMessagePath`, `revisionHistoryLimit`,
`volumeClaimTemplates[].spec.volumeMode`, …) that Argo then flags forever. The child app
stays OutOfSync, root waits on it at that wave, and **a brand-new Application at a later
wave never materialises**. Symptom: root reports "all tasks run" while the resource is
simply absent. Escape hatch: `kubectl apply -f bootstrap/app-<name>.yaml` once, Argo owns
it from then on. Real fix: an `ignoreDifferences` block listing the defaulted pointers.

**Env-var `$(VAR)` interpolation is order-dependent.** A `value:` string referencing
another env var only resolves it if that var is declared **earlier** in the same
container's `env` list. Declare `secretKeyRef` vars first, composed strings after. The
failure is silent: empty strings get substituted and the app reports a downstream auth
error that reads like a bad password.

**RWO PVC + default RollingUpdate = Multi-Attach deadlock** for any single-replica
workload with block storage. The surge pod schedules on a different node, the volume
cannot attach twice, and the new pod sits in `ContainerCreating` until you kill the old
one by hand. For one replica on RWO the answer is `strategy.type: Recreate`; many charts
hardcode RollingUpdate and expose no knob, in which case a PostSync-hook Job that patches
the live Deployment is the workaround.

**Argo caches hook manifests stubbornly.** Push a fix to a PreSync/PostSync hook and the
repo-server can keep rendering the pre-fix spec through hard refresh and pod restarts.
Rename the hook resource (`-v2`) so Argo treats it as new.

## Day-2 cheat sheet

```bash
# force a sync now
kubectl -n argocd patch app <name> --type merge \
  -p '{"operation":{"initiatedBy":{"username":"manual"},"sync":{"revision":"HEAD"}}}'

# nudge a stuck SopsSecret
kubectl -n <ns> annotate sopssecret <name> reconcile-$(date +%s)=x --overwrite

# roll back a bad deploy — no kubectl needed, that is the whole point
git revert <bad-commit> && git push
```

Adding an app: create `apps/<name>/values.yaml`, copy an existing two-source Application
to `bootstrap/app-<name>.yaml`, add `apps/<name>/*.sops.yaml` plus a single-source
`app-<name>-secrets.yaml` if it needs secrets, push. Root picks it up.

## Version pins

| Component | Version |
| --- | --- |
| Forgejo | 10.x (`codeberg.org/forgejo/forgejo:10`) |
| Argo CD | v3.4.5 (chart `argo/argo-cd 10.2.1`) |
| sops-secrets-operator | 0.16 (chart 0.28.0) |
| sops | 3.13.2 |
| age | 1.2.1 |
