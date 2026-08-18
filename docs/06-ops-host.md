# 06 · Ops host (Raspberry Pi 5)

An out-of-cluster box doing three jobs the cluster should not do for itself:

1. **Observability** — Prometheus, Loki, Tempo and Grafana, scraping the cluster from
   outside so they survive a total-cluster incident or a `tofu destroy`. Don't monitor a
   thing with itself.
2. **Git** — Forgejo behind its own Cloudflare tunnel, so the source of truth outlives
   the cluster.
3. **Management** — `talosctl`, `kubectl`, `helm`, `tofu`, the Terraform state, and the
   backup crons.

It is explicitly **not** a Kubernetes node. Do not `talosctl apply-config` to it.

Rebuild from a fresh Debian install with
[`scripts/bootstrap-ops-host.sh`](../scripts/bootstrap-ops-host.sh) — idempotent, safe to
re-run.

## Hardware

| Item | Notes |
| --- | --- |
| Raspberry Pi 5 8 GB | arm64, PCIe on the underside |
| NVMe HAT + ~256 GB NVMe | Or a USB 3 SSD. **Do not run this from an SD card** — Prometheus writes will kill it in months |
| PoE+ HAT or USB-C 5 A PSU | |
| Case with a fan | The Pi 5 throttles under sustained load without active cooling |

IP `192.168.1.100`, reserved.

## Layout

```
/opt/lab/
├── tofu/           the OpenTofu roots (cluster, n8n)
├── kube/config     kubeconfig from `tofu output`
├── talos/config    talosconfig from `tofu output`
├── talos-images/   factory ISO + schematic.txt
└── cron/           backup scripts
/opt/obs/           Prometheus + Loki + Tempo + Grafana compose stack
/opt/git/           Forgejo + cloudflared + Actions runner compose stack
/mnt/data/          bind-mount root for all of the above
/mnt/nas/           NFS mount of the NAS backup share
```

`/mnt/data/*` bind mounts mean the storage backend (SD card now, NVMe later) is a mount
decision, not a YAML change.

## Observability stack

```yaml
# /opt/obs/compose.yaml
services:
  prometheus:
    image: prom/prometheus:v2.55.0
    user: "65534:65534"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /mnt/data/prom:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
      - --web.enable-remote-write-receiver     # Tempo pushes exemplars here
    ports: ["127.0.0.1:9090:9090"]
    extra_hosts: ["host.docker.internal:host-gateway"]
    restart: unless-stopped

  loki:
    image: grafana/loki:3.2.0
    user: "10001:10001"
    command: ['-config.file=/etc/loki/config.yaml']
    volumes:
      - ./loki-config.yaml:/etc/loki/config.yaml:ro
      - /mnt/data/loki:/loki
    ports: ["3100:3100"]        # LAN-reachable — in-cluster Alloy pushes here
    restart: unless-stopped

  tempo:
    image: grafana/tempo:2.6.1
    volumes:
      - ./tempo.yaml:/etc/tempo.yaml:ro
      - /mnt/data/tempo:/var/tempo
    ports: ["3200:3200", "4317:4317", "4318:4318"]
    restart: unless-stopped

  grafana:
    image: grafana/grafana:11.3.0
    user: "472:0"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GF_SECURITY_ADMIN_PASSWORD}   # /opt/obs/.env, mode 600
    volumes: ["/mnt/data/grafana:/var/lib/grafana"]
    ports: ["3000:3000"]        # the only externally exposed port
    restart: unless-stopped
```

Chown the bind mounts to the container UIDs above (65534, 10001, 472) or nothing starts.

### Scraping the cluster from outside

Discovery via the Kubernetes API, scraping through the **API-server proxy**. One bearer
token, no per-service LoadBalancer, and new pods are covered automatically.

```yaml
# /opt/obs/prometheus.yml (one job; the others follow the same shape)
- job_name: k8s-kube-state-metrics
  scheme: https
  tls_config:    { ca_file: /etc/prometheus/k8s-ca.crt, insecure_skip_verify: true }
  authorization: { credentials_file: /etc/prometheus/k8s-token }
  kubernetes_sd_configs:
    - role: endpoints
      api_server: https://192.168.1.110:6443
      tls_config:    { ca_file: /etc/prometheus/k8s-ca.crt, insecure_skip_verify: true }
      authorization: { credentials_file: /etc/prometheus/k8s-token }
      namespaces: { names: [monitoring] }
  relabel_configs:
    - target_label: cluster            # community k8s dashboards filter on {cluster="$cluster"}
      replacement: talos-lab
    - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_pod_container_port_number]
      regex: kube-state-metrics;8080
      action: keep
    - source_labels: [__address__]
      replacement: 192.168.1.110:6443
      target_label: __address__
    - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_name, __meta_kubernetes_pod_container_port_number]
      regex: (.+);(.+);(.+)
      target_label: __metrics_path__
      replacement: /api/v1/namespaces/$1/pods/$2:$3/proxy/metrics
```

Same pattern for node-exporter, app `/metrics` endpoints, and — with `role: node` — the
kubelet's `/metrics` and `/metrics/cadvisor`, which is what feeds per-pod CPU and memory
panels.

Cluster side, the RBAC it needs:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: prometheus-external }
rules:
  - apiGroups: ['']
    resources: [nodes, nodes/proxy, nodes/metrics, services, services/proxy,
                endpoints, pods, pods/proxy]
    verbs: [get, list, watch]
  - nonResourceURLs: [/metrics, /metrics/cadvisor]
    verbs: [get]
```

plus a ServiceAccount, a binding, and a long-lived token Secret annotated
`kubernetes.io/service-account.name`. Copy the token and CA to the Pi and mount them into
the Prometheus container.

**The cluster runs only exporters** — `node-exporter` DaemonSet and `kube-state-metrics`,
plain Helm charts, no operator, no CRDs. The `monitoring` namespace needs
`pod-security.kubernetes.io/enforce=privileged`, since node-exporter wants hostPID and
hostNetwork.

### Logs — Grafana Alloy → Loki

A `grafana/alloy` DaemonSet in the cluster tails `/var/log/pods/**` and pushes to the Pi.
(Alloy rather than promtail, which is EOL.)

```
discovery.kubernetes "pods" { role = "pod" }

discovery.relabel "pod_logs" {
  targets = discovery.kubernetes.pods.targets
  // → namespace, pod, container, node, app, component labels
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pod_logs.output
  forward_to = [loki.process.pi.receiver]
}

loki.process "pi" {
  stage.match {
    selector = `{namespace="longhorn-system", container=~"engine|instance-manager"} |= "periodicRefresh"`
    action   = "drop"
  }
  forward_to = [loki.write.pi.receiver]
}

loki.write "pi" {
  endpoint { url = "http://192.168.1.100:3100/loki/api/v1/push" }
  external_labels = { cluster = "talos-lab" }
}
```

Alloy also needs the `privileged` PSA label for the `/var/log/pods` host mount.

> **River syntax gotcha:** block attributes must be newline-separated.
> `rule { source_labels = [...] target_label = "x" }` is a syntax error. Worse, the
> config-reloader fails **silently** — Alloy keeps running the last good config, so a
> broken `helm upgrade` looks successful.

### Traces — Alloy OTLP receiver → Tempo

The same Alloy DaemonSet doubles as the in-cluster OTLP collector: `otelcol.receiver.otlp`
on `0.0.0.0:4318` and `:4317`, batched, exported to the Pi's Tempo. A dedicated
`Service/alloy-otlp` (ClusterIP, both ports) gives workloads a stable DNS name.

n8n emits one span per workflow execution and one per node, so **an idle instance
produces no spans** — verify the pipeline with a real run or a synthetic OTLP push, not
by waiting.

Wire the Grafana Tempo datasource with `tracesToLogsV2` (span → matching Loki lines by
`service.name`) and `tracesToMetrics`.

### Dashboards and datasources

Provision both **from files**, not the UI:
[`iac/platform/grafana-datasources.yaml`](../iac/platform/grafana-datasources.yaml) and
[`iac/platform/grafana-dashboards.yaml`](../iac/platform/grafana-dashboards.yaml), mounted
under `/etc/grafana/provisioning/`. That is the difference between an observability stack
you can rebuild and one you have to remember.

> Partly retrofitted. The dashboards are now exported to files and shipped here, but the
> lab's own Grafana still has its **datasources** clicked in — they carry random UIDs like
> `cft4er82n82yod` rather than the stable ones `grafana-datasources.yaml` declares, which
> is exactly the drift that makes a raw dashboard export unusable elsewhere. So the
> datasource file here is still the fix rather than a mirror. If you are starting fresh,
> start provisioned; it costs nothing on day one and is tedious to retrofit.

Four datasources: **Prometheus**, **Loki**, **Tempo** (with `tracesToLogsV2` so a span
jumps to its log lines), and **n8n-postgres** — a direct read used by the workflow
analytics dashboard, which queries n8n's schema rather than Prometheus. That last one
needs the cluster's Postgres reachable on the LAN; see
[`iac/platform/cnpg-lan-service.yaml`](../iac/platform/cnpg-lan-service.yaml).

| ID | Dashboard (as titled in Grafana) | Reads from |
| --- | --- | --- |
| — | n8n on Talos — *pick namespace/instance* | Prometheus + Loki — the landing page |
| 24474 | n8n System Health Overview — *pick instance* | Prometheus — Node.js heap, GC, event loop |
| 24475 | n8n Workflow & Execution Analytics | Postgres — success rates, throughput, per-workflow trends. Reports on whichever instance `n8n-postgres` points at |
| 1860 | Node Exporter Full | Prometheus — per-node CPU/mem/disk/net/temps |
| 15757 | Kubernetes / Views / Global | Prometheus — namespaces, workloads, pressure |
| 15759 | Kubernetes / Views / Nodes | Prometheus — allocatable vs allocated |
| 15760 | Kubernetes / Views / Pods | Prometheus — restarts, throttling, OOMs |

All seven are vendored at
[`iac/platform/dashboards/`](../iac/platform/dashboards/) — copy the directory into the
provisioning path and they load within 30 seconds:

```bash
cp iac/platform/dashboards/*.json /mnt/data/grafana/dashboards/
```

Their datasource UIDs were rewritten to the stable ones
`grafana-datasources.yaml` provisions (`prometheus`, `loki`, `tempo`,
`n8n-postgres`). A UI-created datasource gets a random UID like `cft4er82n82yod`, and an
export bakes it into every panel, so a raw export is useless on any other machine: the
dashboard loads and every panel reads *Datasource not found*. Attribution and the full
mapping are in [`iac/platform/dashboards/README.md`](../iac/platform/dashboards/README.md).

**Put the required template variable in the dashboard title.** The `— pick
namespace/instance` suffixes above are deliberate. Several of these render blank until you
select a value, and a blank dashboard is indistinguishable from a broken one at a glance —
particularly six months later, or for anyone who is not you. Naming the variable in the
title turns "this is broken" into "set the dropdown". Where a dashboard is pinned to one
instance, put *that* in the title instead, so a second n8n deployment can't be misread as
the first.

The first row is the hand-built landing page, the only original in the set:
[`iac/platform/dashboards/n8n-on-talos.json`](../iac/platform/dashboards/n8n-on-talos.json).
Twelve panels — pod counts per role, queue depth, cache hit rate, node CPU and memory,
pod count by namespace, pods not Running, plus two logs panels (live n8n main, and a
cluster-wide error/warning filter).

It carries `DS_PROMETHEUS` and `DS_LOKI` **datasource-type template variables**, so it
binds to whatever datasources exist on import rather than to the UIDs of the Grafana it
was built on. Worth doing for any dashboard you intend to share: the alternative is a
dashboard that renders empty on every machine but yours, with no error explaining why.

For your own dashboards, either build them that way or export with **Share → Export →
"Export for sharing externally"**, which rewrites the hardcoded UIDs into `__inputs`
prompts at import time.

**Two things make these work, and both fail quietly:**

- **The `cluster` label.** Every `157xx` dashboard filters on `{cluster="$cluster"}` and
  renders completely empty without it. The scrape config injects it with a static relabel.
  Nothing warns you — the panels just say "No data".
- **The kubelet cadvisor job.** Pod-level CPU and memory panels read `container_*` and
  `machine_*`, which come from `/metrics/cadvisor` on the kubelet — not from node-exporter
  and not from kube-state-metrics. Miss that scrape job and the dashboard loads, most
  panels populate, and only the per-pod ones are blank, which reads as a broken dashboard
  rather than a missing target.

### Retention

| Store | Retention | Configured in |
| --- | --- | --- |
| Prometheus | 30 d | `--storage.tsdb.retention.time` |
| Loki (default) | 7 d | `limits_config.retention_period` |
| Loki (ingress, app namespaces) | 30 d | `limits_config.retention_stream` |
| Tempo | 14 d | `compactor.compaction.block_retention` |

Loki's default is **never expire**. Set this on day one, not after the disk fills.

## Forgejo

```yaml
# /opt/git/compose.yaml
services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:10
    environment:
      FORGEJO__server__ROOT_URL:   'https://git.example.com/'
      FORGEJO__server__DOMAIN:     'git.example.com'
      FORGEJO__server__HTTP_PORT:  '3000'
      FORGEJO__server__SSH_PORT:   '222'
      FORGEJO__database__DB_TYPE:  'sqlite3'
      FORGEJO__service__DISABLE_REGISTRATION: 'true'
      FORGEJO__security__INSTALL_LOCK:        'true'
      FORGEJO__webhook__ALLOWED_HOST_LIST:    '192.168.1.203'   # in-cluster webhook receivers
      FORGEJO__actions__DEFAULT_ACTIONS_URL:  'https://github.com'
    volumes: ["/mnt/data/forgejo:/data"]
    ports: ['3001:3000', '222:22']
  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${TUNNEL_TOKEN}
    depends_on: [forgejo]
```

Argo pulls over the LAN URL `http://192.168.1.100:3001/<user>/homelab-gitops.git`; humans
use `https://git.example.com/`.

**`webhook.ALLOWED_HOST_LIST` defaults to `external`, which blocks every private IP.** A
webhook aimed at a LAN address is refused before the request leaves the container, with
`webhook can only call allowed HTTP servers` in Forgejo's log and *nothing at all* in the
receiver's. Delivery is marked failed and **is not retried** — fixing the allowlist
replays nothing, so re-trigger the event.

### Actions runner

`data.forgejo.org/forgejo/runner:13.0.0`, in the same compose stack, labels mapped to
`catthehacker/ubuntu:act-latest` (which publishes arm64 — required on a Pi).

- Register with a **shared secret**, not a registration token:
  `forgejo forgejo-cli actions register --secret <s> --scope <user> --name pi-ops-runner`.
  Idempotent — re-running updates rather than duplicates.
- The daemon needs `/data/.runner` or it exits with `0 server connections configured`.
  Run `forgejo-runner create-runner-file` before `daemon`.
- Needs the **docker group**, not just the socket mount: `user: '1000:1000'` plus
  `group_add: ['<docker-gid>']`. Jobs run as sibling containers on the host daemon, which
  is root-equivalent access to this host — acceptable only for private repos.
- **Containers on this host cannot reach the host's own LAN IP.** Hairpinning back to
  `192.168.1.100:3001` from inside a container times out even though the same URL works
  from the host shell and from the cluster. Use the compose DNS name
  (`http://forgejo:3000`) and set the runner's `container.network` to the compose network.
  Symptom if wrong: the daemon logs `Starting runner daemon`, looks fine for 60 s, dies
  with `fail to invoke Declare … context deadline exceeded`, and restart-loops. A healthy
  runner logs `declared successfully` and `[poller] launched`.
- `DEFAULT_ACTIONS_URL: https://github.com` — Forgejo otherwise resolves `uses:` against
  `code.forgejo.org`, which mirrors `actions/*` but not third-party actions.
- **Queued runs are inert without a runner** and the UI just says `Waiting` forever, with
  no error anywhere.
- **CI triggers are a load decision on shared hardware.** A full test matrix per commit
  can queue faster than one Pi drains it; `workflow_dispatch:` is a reasonable answer.

## Backups

```cron
15 2 * * * root /opt/lab/cron/etcd-snapshot.sh  >> /var/log/etcd-snapshot.log 2>&1
30 3 * * * root /opt/lab/cron/pi-selfbackup.sh  >> /var/log/pi-selfbackup.log 2>&1
```

See [`scripts/etcd-snapshot.sh`](../scripts/etcd-snapshot.sh). Three things that will
bite you:

- **Use absolute paths in cron scripts.** Cron's `PATH` lacks `/usr/local/bin`. A bare
  `talosctl` silently ate nineteen nights of snapshots before anyone read the log.
- **`rsync -a --no-o --no-g`** — root-squashed NAS exports make plain `rsync -a` die on
  `chown` with exit 23.
- **`--delete` is what propagates retention** to the NAS. Drop it and the NAS grows
  forever. Conversely, never point another system's backup target *inside* a tree that a
  `--delete` mirror owns.

Two copies: NAS (copy 1) and local disk (copy 2). Both scripts check `mountpoint -q`
first and warn to stderr rather than syncing into an empty mount point.

**Still missing here, and worth adding:** a nightly check that the newest Longhorn backup
is under 36 hours old. Cheapest version is
`kubectl -n longhorn-system get backups.longhorn.io` and an assertion on
`.status.backupCreatedAt`. A backup job that stops silently is the same as no backup.

Skipped deliberately: a full Alertmanager stack. Grafana's built-in contact points cover
the lab case; add Alertmanager when there is an actual on-call rotation.

## Firewall

UFW: deny incoming by default, allow SSH, Grafana (3000), Loki (3100) and node-exporter
(9100) from the LAN only, plus the Docker bridge range to 9100 so the containerised
Prometheus can scrape the host exporter.
