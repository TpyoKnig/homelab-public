# Talos Kubernetes Homelab

A 3-node HA Talos Linux Kubernetes cluster plus a Raspberry Pi ops host, built entirely
from OpenTofu and reconciled by Argo CD. Everything external is reached through a
Cloudflare Tunnel — no inbound port is open on the LAN.

This repo is the sanitised, publishable version of a lab that actually runs. IPs, domain
and hostnames are placeholders (`example.com`, `192.168.1.0/24`); the architecture,
gotchas and command sequences are real.

```
                    ┌───────────────── Home LAN 192.168.1.0/24 ─────────────────┐
                    │                                                           │
                    │  ┌────────┐    ┌────────┐    ┌────────┐    ┌───────────┐  │
                    │  │ node-1 │    │ node-2 │    │ node-3 │    │  pi-ops   │  │
                    │  │ CP+etcd│    │ CP+etcd│    │ CP+etcd│    │ Pi 5, .100│  │
                    │  │  .101  │    │  .102  │    │  .103  │    │ Prom/Loki │  │
                    │  └────┬───┘    └────┬───┘    └────┬───┘    │ Grafana   │  │
                    │       └─── VIP .110 ─┴────────────┘        │ Forgejo   │  │
                    │                                            └─────┬─────┘  │
                    │  Cilium CNI · Longhorn · ingress-nginx .200       │        │
                    │  cert-manager · KEDA · Argo CD                    │        │
                    └───────────┬──────────────────────────────────────┬┘        │
                                │ cloudflared (in-cluster)             │ cloudflared
                                │  tunnel: cluster                     │  tunnel: pi-ops
                                ▼                                      ▼
                         Cloudflare edge  ── *.example.com ──  git.example.com
```

Two independent tunnels on purpose: if the cluster is gone, git — the source of truth —
is still reachable, and the cluster can be rebuilt from it.

## Contents

| Doc | What |
| --- | --- |
| [STORY.md](STORY.md) | The build log — why it looks like this, what it cost, what broke. Start here if you're deciding whether to build one |
| [BOOTSTRAP.md](BOOTSTRAP.md) | Bare metal → running workloads, in order, with verify steps |
| [docs/01-hardware-and-network.md](docs/01-hardware-and-network.md) | The three machines, the Pi, BIOS, IP plan |
| [docs/02-talos-cluster.md](docs/02-talos-cluster.md) | Talos image factory + the OpenTofu cluster root |
| [docs/03-platform-layer.md](docs/03-platform-layer.md) | Cilium, Longhorn, cert-manager, ingress-nginx, KEDA |
| [docs/04-cloudflare.md](docs/04-cloudflare.md) | Tunnel model, per-hostname DNS, DNS-01 certs |
| [docs/05-gitops.md](docs/05-gitops.md) | Forgejo + Argo CD + SOPS/age, and the app pattern |
| [docs/06-ops-host.md](docs/06-ops-host.md) | Off-cluster observability, Forgejo, backups |
| [docs/07-n8n.md](docs/07-n8n.md) | n8n Community via `terraform-kubernetes-n8n`, split ingress, driven from Argo |
| [docs/08-n8n-sandbox.md](docs/08-n8n-sandbox.md) | `n8n-sandbox-service` for AI Assistant code execution, in `dind` mode |
| [docs/09-searxng.md](docs/09-searxng.md) | Self-hosted metasearch, also the assistant's search backend |
| [docs/10-pr-agent.md](docs/10-pr-agent.md) | AI code review on every Forgejo PR |
| [iac/](iac/) | The OpenTofu roots, platform values, Argo manifests |
| [scripts/](scripts/) | Ops-host bootstrap, etcd snapshots, Cloudflare DNS helper |

### How `iac/` is organised

Split by **how a thing is deployed**, not by what it is. A workload with a Helm chart keeps
its values under `apps/`; a workload deployed by OpenTofu keeps its root under `tofu/`.
n8n appears in both, and the reason is explained under the table below.

```
iac/
├── tofu/          OpenTofu roots — run by tofu-controller, or by hand
│   ├── cluster/       the Talos cluster itself
│   └── n8n/           the n8n module call + caller-owned ingress and RWX PVC
├── platform/      cluster plumbing installed before GitOps takes over
│                  (Cilium, Longhorn, cert-manager, ingress-nginx, cloudflared,
│                   Grafana provisioning + the custom dashboard JSON)
├── apps/          per-workload config, one directory per workload
│   ├── n8n/           minimal registry-sourced module call — the short path
│   ├── searxng/       Helm values          → two-source Application
│   ├── n8n-sandbox/   Helm values + CA     → two-source Application
│   └── pr-agent/      raw manifests        → single-source Application
└── argocd/        the Applications themselves, plus the CRs they own
```

Which shape a workload takes depends on what upstream publishes:

| Upstream publishes | Deployment shape | Config lives in | Example |
| --- | --- | --- | --- |
| A Helm chart | Two-source Application: chart + `ref: values` | `apps/<name>/values.yaml` | searxng, n8n-sandbox |
| Nothing (raw YAML) | Single-source Application: `path:` | `apps/<name>/*.yaml` | pr-agent |
| A Terraform module | A `Terraform` CR run by tofu-controller | `tofu/<name>/*.tf` | n8n |

**n8n has two entry points, and the difference is routing, not packaging.** Both are the
same module; publishing it to the Terraform registry is what made the short one possible.

[`apps/n8n/`](iac/apps/n8n/) is a self-contained ten-line module call, `source` +
`version` straight from the registry. `terraform apply` and you have queue-mode n8n with
Postgres, Valkey and TLS. Start there.

[`tofu/n8n/`](iac/tofu/n8n/) is what this lab actually runs: the same module with
`create_ingress = false`, plus a caller-owned split ingress and an RWX volume. That exists
because Community edition has no SSO, so authentication has to live at the ingress, and one
hostname cannot serve both an allowlisted editor and open webhooks.

Neither is a Helm Application, so `apps/n8n/` holds `.tf` where the other app directories
hold `values.yaml`, and it is still OpenTofu or Terraform that applies it.

That is a choice, not an absence. Upstream **does** publish a chart at
[`n8n-io/n8n-hosting`](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n), and it
is a capable one: queue mode, workers, webhook processors, multi-main, KEDA. It expects
Postgres and Redis to already exist though (`database.useExternal`, `redis.useExternal`),
so the chart is one of three things you would have to assemble. The module provisions
CloudNativePG and Valkey itself, which makes the whole workload a single `apply` and its
version a single line in git. If you already run Postgres and Redis, the upstream chart is
the more obvious path and this repo's `apps/` pattern would fit it unchanged.

⚠️ The registry `source` form works under **Terraform** only. OpenTofu resolves module
registry addresses against a different index that does not carry this module — use the
`git::…?ref=` form there. Details in [docs/07](docs/07-n8n.md#calling-the-module).

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Topology | 3× control-plane, all schedulable | True HA on three boxes; node-loss is testable |
| Provisioning | OpenTofu + `siderolabs/talos` | Reproducible; the cluster is a `tofu apply` |
| CNI | Cilium, kube-proxy replacement | Network policy + Hubble; one fewer component |
| LoadBalancer | Cilium LB IPAM + L2 announcements | No MetalLB |
| Storage | Longhorn on the node NVMe | Replicated PVs; survives one node down |
| Ingress / TLS | ingress-nginx + cert-manager (DNS-01) | Same cert works via tunnel and via LAN IP |
| External access | Cloudflare Tunnel, no port forwards | Nothing inbound; no LAN IP is public |
| GitOps | Forgejo (on the Pi) + Argo CD + SOPS/age | Git survives the cluster; secrets editable offline |
| Observability | Prometheus/Loki/Tempo/Grafana **off-cluster** | Don't monitor a thing with itself |
| n8n | Community edition via OpenTofu module, run by tofu-controller | No licence; module is the deployment surface, and version bumps stay a git commit |

## Upstream repos used here

- [`TpyoKnig/terraform-kubernetes-n8n`](https://github.com/TpyoKnig/terraform-kubernetes-n8n) — the n8n module (CNPG + Valkey + KEDA + split ingress)
- [`TpyoKnig/n8n-sandbox-service`](https://github.com/TpyoKnig/n8n-sandbox-service) at tag `0.0.1` — isolated code-execution sandboxes for the n8n AI Assistant, in `dataPlane.mode: dind` — the mode that exists for immutable-rootfs distributions, verified on Talos v1.13.7. Its Helm chart is vendored in that repo and **published by git tag only**, so reference the tag or commit rather than a chart version

## Reading the placeholders

| Placeholder | Replace with |
| --- | --- |
| `example.com` | Your Cloudflare-hosted zone |
| `192.168.1.0/24` | Your LAN |
| `203.0.113.10/32` | Your home WAN IP (in the ingress allowlists) |
| `<TUNNEL_UUID>`, `<ZONE_ID>`, `<ACCOUNT_ID>` | Cloudflare identifiers |
| `<SCHEMATIC_ID>` | Your Talos Image Factory schematic |
| `<user>` | Your Forgejo username |

No secret, key, token or real address in this repo is live. `secret_key` and API-key
fields are placeholders that must be regenerated.
