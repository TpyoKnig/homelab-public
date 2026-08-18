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

## What's here, and whose it is

| File | Origin |
|---|---|
| `node-exporter-full.json` | [grafana.com/dashboards/1860](https://grafana.com/grafana/dashboards/1860) by **rfmoz** |
| `kubernetes-views-global.json` | [15757](https://grafana.com/grafana/dashboards/15757) by **dotdc** |
| `kubernetes-views-nodes.json` | [15759](https://grafana.com/grafana/dashboards/15759) by **dotdc** |
| `kubernetes-views-pods.json` | [15760](https://grafana.com/grafana/dashboards/15760) by **dotdc** |
| `n8n-system-health-overview-pick-instance.json` | [24474](https://grafana.com/grafana/dashboards/24474) by **nluecke**, modified |
| `n8n-workflow-execution-analytics-n8n-local-prod.json` | [24475](https://grafana.com/grafana/dashboards/24475) by **nluecke**, modified |
| `n8n-on-talos.json` | original |

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
