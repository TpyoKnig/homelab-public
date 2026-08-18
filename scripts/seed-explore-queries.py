#!/usr/bin/env python3
"""Seed Grafana Explore's Starred queries with the ones worth keeping.

Grafana 11.3 has no shareable "query library" - that arrived later. What it does
have is per-user query history with a starred flag, and an API to write to it.
This seeds that, so Explore opens with the useful queries one click away in
Starred instead of everyone retyping TraceQL from memory.

Caveats worth knowing before you rely on this:

  * Query history is PER USER. Seeding as admin does not give other users these
    queries. Re-run it per login, or accept that it is an admin convenience.
  * These are queries, not dashboards. Anything you want to watch continuously
    belongs on a dashboard; Explore is for the ad-hoc follow-up.

Idempotent: entries are matched by their comment, so re-running updates rather
than duplicating.

Usage:
    GF_URL=http://localhost:3000 GF_USER=admin GF_PASS=... ./seed-explore-queries.py
    ./seed-explore-queries.py --dry-run
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request

GF_URL = os.environ.get("GF_URL", "http://localhost:3000").rstrip("/")
GF_USER = os.environ.get("GF_USER", "admin")
GF_PASS = os.environ.get("GF_PASS")
DRY_RUN = "--dry-run" in sys.argv

# Datasources are looked up by NAME, because a datasource created through the UI
# gets a random UID and hardcoding one makes this script useless to anyone else.
PROM, TEMPO, LOKI = "Prometheus", "Tempo", "Loki"

# (datasource name, label shown in Starred, query object)
#
# The Prometheus entries below query traces_spanmetrics_* - series Tempo's
# metrics-generator derives from n8n's OpenTelemetry spans, not anything n8n
# exposes itself. See iac/platform/tempo-metrics-generator.yaml.
QUERIES = [
    (PROM, "n8n | node p95 latency by node type", {
        "refId": "A",
        "expr": 'histogram_quantile(0.95, sum by (n8n_node_type, le) '
                '(rate(traces_spanmetrics_latency_bucket{span_name="node.execute", '
                'n8n_node_type!=""}[$__rate_interval])))',
    }),
    (PROM, "n8n | Code node: JS runner vs Python runner (mean)", {
        "refId": "A",
        "expr": 'sum by (n8n_node_name) (rate(traces_spanmetrics_latency_sum'
                '{n8n_node_type="n8n-nodes-base.code"}[$__rate_interval])) / '
                'sum by (n8n_node_name) (rate(traces_spanmetrics_latency_count'
                '{n8n_node_type="n8n-nodes-base.code"}[$__rate_interval]))',
    }),
    (PROM, "n8n | node executions/sec by type", {
        "refId": "A",
        "expr": 'sum by (n8n_node_type) (rate(traces_spanmetrics_calls_total'
                '{span_name="node.execute", n8n_node_type!=""}[$__rate_interval]))',
    }),
    (PROM, "n8n | node errors/sec by type", {
        "refId": "A",
        "expr": 'sum by (n8n_node_type) (rate(traces_spanmetrics_calls_total'
                '{span_name="node.execute", status_code="STATUS_CODE_ERROR"}'
                '[$__rate_interval]))',
    }),
    (PROM, "n8n | workflow p95 vs slowest single node", {
        "refId": "A",
        "expr": 'histogram_quantile(0.95, sum by (span_name, le) '
                '(rate(traces_spanmetrics_latency_bucket{span_name=~"workflow.execute|node.execute"}'
                '[$__rate_interval])))',
    }),
    # Native n8n metrics. Counters are summed because an execution is recorded
    # once by the process that ran it; shared-state gauges would need max().
    (PROM, "n8n | executions/sec by status (native metric)", {
        "refId": "A",
        "expr": 'sum by (job, status) (rate(n8n_workflow_execution_duration_seconds_count'
                '[$__rate_interval]))',
    }),
    (PROM, "n8n | queue depth (native metric)", {
        "refId": "A",
        "expr": 'max by (job) (n8n_scaling_mode_queue_jobs_waiting)',
    }),

    (TEMPO, "n8n | slow executions (>1s)", {
        "refId": "A", "queryType": "traceql",
        "query": '{name="workflow.execute" && duration > 1s}',
    }),
    (TEMPO, "n8n | slow Code nodes (>1s)", {
        "refId": "A", "queryType": "traceql",
        "query": '{name="node.execute" && span.n8n.node.type="n8n-nodes-base.code" '
                 '&& duration > 1s}',
    }),
    # Node TYPE cannot tell the two task runners apart - a Code node is
    # n8n-nodes-base.code either way and n8n puts no language attribute on the
    # span. The node NAME is the only discriminator, so this one depends on the
    # workflow author's naming.
    (TEMPO, "n8n | Python task-runner nodes only", {
        "refId": "A", "queryType": "traceql",
        "query": '{span.n8n.node.name=~".*Python.*"}',
    }),
    (TEMPO, "n8n | failed executions", {
        "refId": "A", "queryType": "traceql",
        "query": '{name="workflow.execute" && status=error}',
    }),
    # Returns nothing until a workflow actually pushes that many items through a
    # single node - tune the threshold to your workloads rather than assuming it
    # is broken. It is not: the item-count attributes are genuinely numeric in
    # TraceQL and `> 100` filters correctly, even though the trace API renders
    # them as JSON strings ("n8n.node.items.input": "1"). Comparing them as
    # strings is what silently matches nothing.
    (TEMPO, "n8n | heaviest nodes by item count", {
        "refId": "A", "queryType": "traceql",
        "query": '{name="node.execute" && span.n8n.node.items.input > 100}',
    }),

    (LOKI, "n8n | task-runner launcher log", {
        "refId": "A", "queryType": "range",
        "expr": '{namespace="n8n-community", container="task-runner"}',
    }),
    (LOKI, "n8n | errors across all n8n pods", {
        "refId": "A", "queryType": "range",
        "expr": '{namespace=~"n8n.*"} |~ "(?i)error|fatal|exception"',
    }),
]


def api(path, method="GET", body=None):
    req = urllib.request.Request(f"{GF_URL}{path}", method=method)
    token = base64.b64encode(f"{GF_USER}:{GF_PASS}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read() or "{}")


def main():
    if not GF_PASS:
        sys.exit("GF_PASS is not set. Export it, or source your Grafana env file.")

    uid_by_name = {d["name"]: d["uid"] for d in api("/api/datasources")}
    missing = {n for n, _, _ in QUERIES} - uid_by_name.keys()
    if missing:
        sys.exit(f"Datasource(s) not found by name: {sorted(missing)}. "
                 f"Have: {sorted(uid_by_name)}")

    existing = {}
    # An empty history returns queryHistory: null, not [], so `or []` is load-bearing.
    history = api("/api/query-history?onlyStarred=true&limit=100").get("result") or {}
    for e in history.get("queryHistory") or []:
        if e.get("comment"):
            existing[e["comment"]] = e["uid"]

    created = updated = 0
    for ds_name, comment, query in QUERIES:
        if DRY_RUN:
            print(f"  [dry-run] {ds_name:11} {comment}")
            continue
        if comment in existing:
            # Already seeded. Leave the entry alone rather than churn its uid,
            # which would break any bookmark pointing at it.
            print(f"  = {ds_name:11} {comment}")
            updated += 1
            continue
        res = api("/api/query-history", "POST",
                  {"dataSourceUid": uid_by_name[ds_name], "queries": [query]})
        uid = res.get("result", res).get("uid")
        api(f"/api/query-history/star/{uid}", "POST")
        api(f"/api/query-history/{uid}", "PATCH", {"comment": comment})
        print(f"  + {ds_name:11} {comment}")
        created += 1

    if not DRY_RUN:
        print(f"\n{created} created, {updated} already present. "
              f"Explore -> Query history -> Starred.")


if __name__ == "__main__":
    main()
