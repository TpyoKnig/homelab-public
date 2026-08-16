# 09 · SearXNG

Self-hosted metasearch. Two jobs here: a private search front-end for the household, and
the **web-search backend for n8n's AI Assistant** so queries don't carry a commercial API
key or a stable client identity.

Deployed by Argo CD with the standard two-source pattern — chart from
`https://charts.kubito.dev`, values from git. Manifests:
[`iac/argocd/app-searxng.yaml`](../iac/argocd/app-searxng.yaml) and
[`iac/apps/searxng/values.yaml`](../iac/apps/searxng/values.yaml).

The upstream `searxng/searxng-helm-chart` was archived in 2025-05; the kubito chart is the
maintained one.

## Values that matter

```yaml
replicaCount: 1        # pinned so a chart bump can't silently scale up

image:
  repository: searxng/searxng
  tag: "2026.8.3-aa059419f"    # a real tag — `latest` drifts and Argo won't notice

config:
  settings:
    server:
      secret_key: "<GENERATE: openssl rand -hex 32>"
      limiter: false       # true needs Redis; add when abuse actually happens
      image_proxy: true
    search:
      safe_search: 0
      formats: [html, json]    # json is what makes it usable as an LLM tool
```

`formats: [html, json]` is the load-bearing line for the assistant use case — without
`json`, SearXNG serves humans only.

The `secret_key` signs session cookies and the limiter token, not credentials. It is
still a secret: generate your own and, if you care, deliver it as a `SopsSecret` or via an
`existingSecret` rather than in plaintext values.

## Ingress

Home-only, with the same allowlist pattern used elsewhere in the cluster:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/whitelist-source-range: "203.0.113.10/32,192.168.1.0/24"
  hosts:
    - host: searxng.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - hosts: [searxng.example.com]
      secretName: searxng-tls
```

The LAN `/24` is included so a direct hit on `http://192.168.1.200`, bypassing the tunnel,
still works. The allowlist only works at all because ingress-nginx runs with
`use-forwarded-headers` and `compute-full-forwarded-for` — see
[03-platform-layer](03-platform-layer.md#ingress-nginx).

## As the assistant's search backend

n8n reaches it over cluster DNS, no ingress involved:

```hcl
{ name = "N8N_INSTANCE_AI_SEARXNG_URL", value = "http://searxng-http.searxng.svc.cluster.local:8080" }
```

Two things to know:

**A Brave API key outranks SearXNG.** n8n picks exactly one search backend, in order:
the n8n-hosted proxy (licence-gated), then Brave if a key is set, then SearXNG, then
nothing at all. Setting a Brave key silently removes SearXNG from the path.

**The pod log will not tell you which one ran.** SearXNG has no access log; the only lines
it writes are engine-error tracebacks, so a successful search is completely silent. That
makes it easy to conclude "SearXNG receives nothing" while it is in fact serving every
query. Check the stored tool output instead — see
[07-n8n](07-n8n.md#ai-assistant-and-agents).

**What this buys, and what it doesn't.** SearXNG queries its own upstreams (Google, Brave,
DuckDuckGo, Wikipedia) *from the cluster*, so this is not LAN-only search. What it buys is
that your commercial API key and your client identity stay out of it.
