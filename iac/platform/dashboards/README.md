# Dashboards

Drop these in the provisioning path from `../grafana-dashboards.yaml`
(`/mnt/data/grafana/dashboards`, mounted at `/var/lib/grafana/dashboards`) and
Grafana picks them up within 30 seconds. No import step, no clicking.

Exported from a running Grafana, with `id` and `version` stripped so they carry
no instance-local state.

## Datasource UIDs are rewritten, and that matters

Grafana assigns a random UID (`cft4er82n82yod`) to any datasource created
through the UI, and an export bakes that UID into every panel. Those exports are
useless to anyone else: the dashboard loads and every panel says *Datasource not
found*.

The four hardcoded UIDs here were rewritten to the stable ones that
`../grafana-datasources.yaml` provisions:

| In these files | Provisioned by |
|---|---|
| `prometheus` | `Prometheus` |
| `loki` | `Loki` |
| `tempo` | `Tempo` |
| `n8n-postgres` | `n8n-postgres` |

So use the datasource file alongside these, or create datasources with those
exact UIDs. If you provision datasources through the UI instead, yours will get
random UIDs and these dashboards will not find them.

The community dashboards below reference `${datasource}` / `${DS_PROMETHEUS}`
template variables rather than fixed UIDs, so they were already portable and
needed no rewriting.

## n8n-full-observability, and the 19 flags behind it

`n8n-full-observability.json` is 30 panels over every metric group n8n 2.34.6 can
emit: executions, webhooks, queue, DB pool, scheduler, execution-data I/O, cache
and per-role process health.

Most of it reports nothing on a default install. `N8N_METRICS=true` enables the
endpoint, but **19 of the 23 `N8N_METRICS_INCLUDE_*` groups default to false**, so
the endpoint looks complete while saying nothing about webhooks, the scheduler, the
DB pool, SSRF blocks or DNS cache. Turning them all on took this instance from 66 to
127 distinct metric names, for about 1,700 extra series — under 2% of this
Prometheus.

Two rules are baked into the queries, and getting either wrong produces
confidently wrong numbers:

- **Counters and histograms use `sum()`.** An execution is recorded once, by the
  process that ran it. Summing across pods is the correct total.
- **Shared-state gauges use `max()`.** `n8n_active_workflow_count` is read from the
  database, so *every* pod reports the same value. `sum()` multiplies it by the pod
  count — and that bites at two replicas, not just at scale.

It uses a `DS_PROMETHEUS` datasource-type variable rather than a fixed UID, so
unlike the exports described below it binds correctly on any Grafana.

## n8n-node-latency-tracing, and why metrics alone could not do this

`n8n-node-latency-tracing.json` is the one dashboard here that is not built on n8n's
own metrics, because n8n's own metrics cannot answer the question it asks.

Prometheus stops at the workflow boundary. `n8n_workflow_execution_duration_seconds`
will tell you an execution took 8 seconds and nothing about where the 8 seconds went,
and there are **no task-runner metrics at all** — `dist/metrics/prometheus/` holds 23
metric services and none of them is about runners. So a Code node sitting 7.8 s waiting
for a Python task runner shows up as an 8 s workflow and nothing more.

n8n does ship the answer, switched off. It has an OpenTelemetry module that emits a
`node.execute` span per node, and it is **not a licensed feature** — module gating is
the `licenseFlag` property on the `@BackendModule` decorator, which `log-streaming`,
`ldap` and `source-control` all carry and `otel` does not. It is already in the module
registry's `defaultModules`, so it loads on every start; `N8N_OTEL_ENABLED=false` is
the only thing stopping it. It declares `instanceTypes: ['main','worker','webhook']`,
which matters, because the worker is what actually runs the node.

The chain is: n8n emits spans → Tempo ingests them → Tempo's metrics-generator converts
them to `traces_spanmetrics_*` and remote-writes to Prometheus → this dashboard queries
those series. So it needs `../tempo-metrics-generator.yaml` and the `N8N_OTEL_*`
settings in `docs/07-n8n.md`; without both, its panels are empty.

**The gotcha worth stealing:** a Code node is `n8n-nodes-base.code` whether it runs on
the JavaScript runner or the Python one, and n8n puts no language attribute on the span.
Only the node *name* separates them, which is why `n8n.node.name` is promoted to a metric
dimension. On this lab that split is 61 ms versus 1,193 ms mean for the same node type —
the single most useful number on the dashboard, and invisible without that dimension.

Node name is author-controlled and unbounded. Fine at lab scale, wrong at real scale;
drop it and use TraceQL there.

It carries its own trace panel, so the span waterfall is on the dashboard rather than
in Explore: the bottom table runs a TraceQL query (`{name="workflow.execute" && duration
> $min_duration}`) against Tempo, and a row opens the waterfall that shows which node
held the execution.

The latency panels also emit **exemplars**, so a spike links straight to the trace that
caused it. Three things have to line up for that, and it fails silently if any is
missing:

| Where | What |
|---|---|
| `tempo.yaml` | `remote_write: send_exemplars: true` |
| Prometheus | `--enable-feature=exemplar-storage` — without it, exemplars are accepted and dropped |
| Prometheus datasource | `exemplarTraceIdDestinations` pointing at the Tempo datasource |

Like `n8n-full-observability`, this one uses a `${datasource}` variable rather than a
fixed UID, so it binds on any Grafana. `${tracesource}` does the same for Tempo.

## Variables are discovered, not hardcoded

The n8n dashboards select their target through **query variables** that read the
values out of Prometheus:

| Variable | Definition |
|---|---|
| `job` / `instance` | `label_values(n8n_version_info, job)` |
| `namespace` | `label_values(kube_deployment_status_replicas_ready{deployment=~"n8n.*"}, namespace)` |

They were originally custom variables holding one hardcoded option — this lab's
Prometheus job name (`k8s-n8n`) and namespace (`n8n`). That works nowhere but the
machine it was exported from, and worse, a dashboard titled *pick instance* whose
dropdown holds exactly one value tells you nothing. Discovered variables populate
from whatever you actually named your scrape job.

Note the `job` label is the **Prometheus scrape job**, not the Kubernetes
namespace. They are unrelated, and a lab can name the job anything.

`n8n-workflow-execution-analytics` has no variable at all: it queries n8n's
Postgres schema directly, so it reports on whichever instance the `n8n-postgres`
datasource points at. Duplicate it and repoint the datasource to cover a second
instance.

## What's here, and whose it is

| File | Origin |
|---|---|
| `node-exporter-full.json` | [grafana.com/dashboards/1860](https://grafana.com/grafana/dashboards/1860) by **rfmoz** |
| `kubernetes-views-global.json` | [15757](https://grafana.com/grafana/dashboards/15757) by **dotdc** |
| `kubernetes-views-nodes.json` | [15759](https://grafana.com/grafana/dashboards/15759) by **dotdc** |
| `kubernetes-views-pods.json` | [15760](https://grafana.com/grafana/dashboards/15760) by **dotdc** |
| `n8n-system-health-overview-pick-instance.json` | [24474](https://grafana.com/grafana/dashboards/24474) by **nluecke**, modified |
| `n8n-workflow-execution-analytics.json` | [24475](https://grafana.com/grafana/dashboards/24475) by **nluecke**, modified |
| `n8n-on-talos.json` | original |
| `n8n-full-observability.json` | original |

The six community dashboards remain under their authors' terms; they are
vendored here for reproducibility, not relicensed. Check the upstream page
before redistributing them further. Only `n8n-on-talos` is mine.

`n8n-on-talos.json` predates the others here and was exported in the portable
form — it binds through `DS_PROMETHEUS` / `DS_LOKI` datasource-type template
variables rather than fixed UIDs, so it needed no rewriting and will bind to
whatever datasources exist wherever you import it. That is the better shape for
anything you intend to share.

## Two things that make the Kubernetes ones work

Both are easy to miss and neither produces an error.

1. **The `cluster` label.** Every 157xx dashboard filters on
   `{cluster="$cluster"}` and renders completely empty without it. The scrape
   config injects it with a static relabel — see `docs/06-ops-host.md`. Nothing
   warns you; the panels just say *No data*.

2. **The kubelet cadvisor job.** Pod-level CPU and memory panels read
   `container_*` and `machine_*` series, which come from `/metrics/cadvisor` on
   the kubelet, not from node-exporter or kube-state-metrics. Miss that scrape
   job and the dashboards load, most panels populate, and only the per-pod ones
   are blank — which reads as a broken dashboard rather than a missing target.

## Editing

`allowUiUpdates: true` is set, so you can rearrange panels in the UI, but
changes are lost on the next file reload. The JSON is the source of truth.
Export back to it with Share → Export → *Export for sharing externally*, which
swaps fixed datasource UIDs for `__inputs` variables.
