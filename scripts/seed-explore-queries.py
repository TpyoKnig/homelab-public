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

Idempotent: entries are matched by their label, so re-running never duplicates.
An unchanged entry is left alone (and re-starred if it was un-starred). Edit a
query in QUERIES and the next run replaces that entry, because Grafana's
PATCH /api/query-history/{uid} updates the comment only — it accepts a body
containing queries and ignores it. Replacing means delete + recreate, so the
entry gets a new uid; there is no API that edits a stored query in place.

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


class ApiError(RuntimeError):
    pass


def api(path, method="GET", body=None):
    req = urllib.request.Request(f"{GF_URL}{path}", method=method)
    token = base64.b64encode(f"{GF_USER}:{GF_PASS}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        # A raw traceback is a poor result for a seeding script that may have
        # already written entries. Surface the status and body instead, and let
        # the caller report how far it got.
        detail = (e.read() or b"").decode(errors="replace").strip()[:300]
        raise ApiError(f"{method} {path} -> HTTP {e.code}: {detail}") from None
    except urllib.error.URLError as e:
        raise ApiError(f"{method} {path} -> cannot reach {GF_URL}: {e.reason}") from None


def fetch_seeded():
    """Map label -> the full existing entry for everything this script wrote.

    Reads the FULL history rather than only starred entries. An entry created
    but not yet starred (interrupted run) or later un-starred by hand is still
    ours, and missing it would create a duplicate on the next run. Pages until
    the API stops returning rows, because a user with more than one page of
    history would otherwise hide the older seeded labels.
    """
    seeded, page = {}, 1
    while True:
        result = api(f"/api/query-history?limit=100&page={page}").get("result") or {}
        # An empty history returns queryHistory: null, not [], so `or []` matters.
        rows = result.get("queryHistory") or []
        if not rows:
            return seeded
        for e in rows:
            if e.get("comment"):
                seeded.setdefault(e["comment"], e)
        page += 1


# Keys this script sets on a query AND that Grafana stores back verbatim.
# Anything outside this set is Grafana's own enrichment (datasource, editorMode,
# range, ...) and is ignored, so an untouched entry is not rewritten every run.
#
# Only put a key here if Grafana actually round-trips it. `limit`, for example,
# is accepted on create and never persisted — including it would make every
# affected entry compare as changed and be recreated on every single run.
MANAGED_KEYS = {"refId", "expr", "query", "queryType"}


def same_query(entry, ds_uid, query):
    """Whether a stored entry already holds exactly the query we want."""
    stored = entry.get("queries") or []
    if entry.get("datasourceUid") != ds_uid or len(stored) != 1:
        return False
    # Compare both directions, but only across MANAGED_KEYS. Checking just the
    # keys present in `query` would miss a REMOVED one: drop `queryType` from a
    # QUERIES entry and the stored copy still carries it, yet every remaining
    # desired key matches, so the edit would never be applied.
    #
    # The reverse check only sees keys in MANAGED_KEYS. Removing a key outside
    # that set — `limit`, say — changes nothing here and triggers no recreate,
    # which is correct: Grafana never stored it, so there is nothing to undo.
    return {k: v for k, v in stored[0].items() if k in MANAGED_KEYS} == \
           {k: v for k, v in query.items() if k in MANAGED_KEYS}


def main():
    if not GF_PASS:
        sys.exit("GF_PASS is not set. Export it, or source your Grafana env file.")

    try:
        uid_by_name = {d["name"]: d["uid"] for d in api("/api/datasources")}
    except ApiError as e:
        sys.exit(f"Could not list datasources: {e}")

    missing = {n for n, _, _ in QUERIES} - uid_by_name.keys()
    if missing:
        sys.exit(f"Datasource(s) not found by name: {sorted(missing)}. "
                 f"Have: {sorted(uid_by_name)}")

    if DRY_RUN:
        for ds_name, comment, _ in QUERIES:
            print(f"  [dry-run] {ds_name:11} {comment}")
        return

    try:
        existing = fetch_seeded()
    except ApiError as e:
        sys.exit(f"Could not read query history: {e}")

    def create(ds_uid, comment, query):
        uid = api("/api/query-history", "POST",
                  {"dataSourceUid": ds_uid, "queries": [query]}).get("result", {}).get("uid")
        if not uid:
            raise ApiError(f"create returned no uid for: {comment}")
        api(f"/api/query-history/star/{uid}", "POST")
        # The label has to be a separate PATCH: the create endpoint takes no
        # comment field.
        api(f"/api/query-history/{uid}", "PATCH", {"comment": comment})

    created = replaced = unchanged = 0
    try:
        for ds_name, comment, query in QUERIES:
            ds_uid = uid_by_name[ds_name]
            entry = existing.get(comment)

            if entry is None:
                create(ds_uid, comment, query)
                print(f"  + {ds_name:11} {comment}")
                created += 1
                continue

            if same_query(entry, ds_uid, query):
                # Nothing to change. Re-star it though: an entry the user
                # un-starred (or one left behind by a run interrupted between
                # create and star) is invisible in Explore -> Starred, and
                # skipping it entirely would leave it that way forever.
                if not entry.get("starred"):
                    api(f"/api/query-history/star/{entry['uid']}", "POST")
                    print(f"  * {ds_name:11} {comment}  (re-starred)")
                else:
                    print(f"  = {ds_name:11} {comment}")
                unchanged += 1
                continue

            # The stored query differs, so the script's copy has been edited.
            # Delete and recreate rather than PATCH: Grafana's
            # PATCH /api/query-history/{uid} updates the COMMENT only — it
            # accepts a body with queries and silently ignores it, which makes
            # a PATCH-based "refresh" look like it worked while changing
            # nothing. Recreating costs the entry its uid; there is no API that
            # edits a stored query in place.
            #
            # Create BEFORE deleting. The reverse order means a failure between
            # the two (network drop, POST returning no uid) destroys the user's
            # existing entry and puts nothing back. Briefly having two entries
            # under one label is recoverable; having none is not.
            create(ds_uid, comment, query)
            api(f"/api/query-history/{entry['uid']}", "DELETE")
            print(f"  ~ {ds_name:11} {comment}  (query changed, recreated)")
            replaced += 1
    except ApiError as e:
        sys.exit(f"\nAborted after {created} created / {replaced} recreated / "
                 f"{unchanged} left alone.\n{e}")

    print(f"\n{created} created, {replaced} recreated, {unchanged} unchanged. "
          f"Explore -> Query history -> Starred.")


if __name__ == "__main__":
    main()
