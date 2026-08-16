# 08 · n8n sandbox service

[`n8n-sandbox-service`](https://github.com/TpyoKnig/n8n-sandbox-service) gives the n8n AI
Assistant somewhere to actually run code. Each sandbox is a Debian container managed by
an in-container Docker daemon, created and torn down over a REST API.

Without it, the assistant loads and chats but every code execution fails.

## Shape

```
n8n-main ──X-Api-Key──> sandbox-api ──gRPC + mTLS──> runner (DinD) ──> sandbox containers
                          :8080                        :8081 (inner bridge)
```

| Component | Role |
| --- | --- |
| `n8n-sandbox-service-api` | The public REST API n8n talks to |
| `n8n-sandbox-service-runner-dind` | Manages sandbox lifecycles via Docker-in-Docker |
| sandbox containers | One per session, from a configurable Debian image |

Authentication is layered: an `X-Api-Key` header on HTTP operations, a bearer token in
gRPC metadata, and mTLS for runner registration.

Key environment variables:

| Variable | Purpose |
| --- | --- |
| `SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE` | Debian image sandboxes are built from |
| `SANDBOX_RUNNER_DEFAULT_DISK_QUOTA_MB` | Per-sandbox writable-layer cap |
| `SANDBOX_RUNNER_DISK_QUOTA_POOL_SIZE_GB` | Loopback pool allocation |
| `SANDBOX_*_GRPC_TLS_*` | Certificate and key paths for mTLS |

Local development is `make up`, which runs `scripts/bootstrap-mtls.sh` to generate TLS
material into `.tls/`. On Kubernetes, use your own CA — cert-manager is already in this
cluster — mount the PEMs from the `Certificate` secrets, and point the `SANDBOX_*_GRPC_TLS_*`
variables at them.

## Running it on Talos: privileged DinD, not sysbox

The vendor Helm chart requires `runtimeClassName: sysbox-runc`. **Sysbox cannot be
installed on Talos.** Its installer works by writing the host's containerd configuration,
and Talos' root filesystem is immutable — there is no supported path to that file, and no
extension provides it.

So the deployment here is hand-rolled: the runner runs as a **privileged** pod with its
own Docker daemon, and the isolation boundary is the DinD container rather than sysbox's
user-namespaced runtime. That is a real, deliberate downgrade in isolation strength.
Accept it only under conditions like these:

- The cluster is on a private LAN with no untrusted tenants.
- The sandbox namespace is its own, with its own CA and its own tokens.
- The only client is the n8n instance, over cluster-internal DNS.

If any of those stops being true, the sysbox path (on a non-Talos node pool) is the
correct answer, not a hardened privileged pod.

## Pin the image tags

Do not run `:latest`. A node that already holds a tag **never re-pulls it**, so an
instance can sit on months-old code after a newer release ships, with nothing anywhere
reporting a version mismatch. Pin both the API and runner images explicitly and bump them
as a deliberate change.

The same applies when standing up a replacement deployment: give it a fresh namespace and
its own CA and tokens rather than reusing the old ones, so the two never share a trust
boundary during the cutover.

## Wiring n8n to it

In the n8n Terraform root (see [07-n8n](07-n8n.md)):

```hcl
{ name = "N8N_INSTANCE_AI_SANDBOX_ENABLED",  value = "true" }
{ name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" }
{ name = "N8N_SANDBOX_SERVICE_URL",          value = "http://sandbox-api.n8n-sandbox.svc.cluster.local:8080" }
```

plus `N8N_SANDBOX_SERVICE_API_KEY` from a Secret.

**The variable names are `N8N_SANDBOX_SERVICE_URL` and `N8N_SANDBOX_SERVICE_API_KEY`.**
n8n's own documentation names `N8N_INSTANCE_AI_SANDBOX_API_URL` and
`N8N_INSTANCE_AI_SANDBOX_API_KEY`; those strings appear in no shipped build. n8n does not
error on an environment variable it never reads, so the documented spelling gives you an
assistant that loads and cannot execute anything, silently. Verified by grepping the
running bundle.

**The URL and the key move together.** The key is per-instance and mirrors the sandbox
service's own auth secret. Rotate one without the other and the editor and assistant chat
keep working while only code execution breaks — which reads as a sandbox outage rather
than a credential mismatch, and sends you debugging the wrong component.

## Verifying

The honest test is running code from the assistant. Before that:

```bash
kubectl -n n8n-sandbox get pods                     # api + runner Running
kubectl -n n8n-sandbox logs deploy/sandbox-api      # runner registered over mTLS
kubectl -n n8n exec deploy/n8n-main -c n8n-main -- \
  sh -c 'echo $N8N_SANDBOX_SERVICE_URL'             # the URL n8n actually holds
```

A runner that fails mTLS registration leaves the API up and answering, so "the API is
healthy" is not evidence the sandbox works.
