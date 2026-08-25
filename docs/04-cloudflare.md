# 04 · Cloudflare — tunnel, DNS, certificates

This is the layer that makes the cluster reachable from the internet. In the Docker world
this job goes to a router port forward or a VPN, and both mean something at home is
listening for the whole internet to find. This setup inverts that.

Before this: every service is LAN-only. After this: every service has a public hostname
that works from anywhere, with zero ports opened on the router.

External access with **no inbound port open** anywhere. `cloudflared` (Cloudflare's
tunnel client) runs in-cluster and dials *out* to Cloudflare's edge. Traffic to
`<host>.example.com` hits Cloudflare, tunnels back to a cloudflared pod, hops to
`ingress-nginx-controller` over ClusterIP (a virtual IP that only routes inside the
cluster), and reaches the workload.

```
browser ──https──> Cloudflare edge ──tunnel──> cloudflared pod ──http──> ingress-nginx ──> workload
```

TLS end to end in the sense that matters: Cloudflare terminates at the edge with its own
certificate, the tunnel leg is encrypted by cloudflared, and the last hop is cleartext on
the pod network.

## Two tunnels, deliberately

| Tunnel | Runs where | Serves |
| --- | --- | --- |
| `cluster` | Deployment inside the cluster | `*.example.com` → ingress-nginx |
| `pi-ops` | Container on the Raspberry Pi | `git.example.com` → Forgejo |

If the cluster is broken, so is the cluster's cloudflared, and so is every hostname it
serves. The Pi's tunnel is a separate process on a separate host with its own DNS route,
so **git stays reachable when the cluster is down** — which is exactly when you need the
source of truth to rebuild from.

## Creating a tunnel (remotely-managed)

Config lives in Cloudflare, not in a local `config.yml`, so every route change is one API
call and the pods only ever hold a connector token (a credential that can run the tunnel
but not reconfigure it).

```bash
# 1. create the tunnel  (token needs Account:Cloudflare Tunnel:Edit)
curl -X POST -H "Authorization: Bearer $CF_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts/$ACCT_ID/cfd_tunnel \
  -d "{\"name\":\"cluster\",\"tunnel_secret\":\"$(head -c32 /dev/urandom | base64)\",\"config_src\":\"cloudflare\"}"
# → returns the tunnel UUID

# 2. fetch the CONNECTOR token — this is what the pod uses, not the API token
curl -H "Authorization: Bearer $CF_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts/$ACCT_ID/cfd_tunnel/$TUNNEL_ID/token

# 3. push the ingress rules
curl -X PUT -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  https://api.cloudflare.com/client/v4/accounts/$ACCT_ID/cfd_tunnel/$TUNNEL_ID/configurations \
  -d '{"config":{"ingress":[
    {"hostname":"*.example.com","service":"http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"},
    {"service":"http_status:404"}
  ]}}'
```

In-cluster Deployment — two replicas, each opening four connections, so eight tunnels to
the edge:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: cloudflared, namespace: cloudflared }
spec:
  replicas: 2
  selector: { matchLabels: { app: cloudflared } }
  template:
    metadata: { labels: { app: cloudflared } }
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2025.1.1
          args: [tunnel, --no-autoupdate, --metrics, "0.0.0.0:2000", run]
          env:
            - name: TUNNEL_TOKEN
              valueFrom: { secretKeyRef: { name: cloudflared-tunnel-token, key: token } }
          livenessProbe:
            httpGet: { path: /ready, port: 2000 }
            initialDelaySeconds: 10
            periodSeconds: 30
```

Verify with `GET /cfd_tunnel/<id>` — `status: healthy` and four connections per pod.

```bash
curl -sS -H "Authorization: Bearer $CF_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts/$ACCT_ID/cfd_tunnel/$TUNNEL_ID \
  | grep -o '"status":"[^"]*"'          # want "status":"healthy"
```

## The wildcard is on the tunnel, not on DNS

This is the single most confusing part of the setup, so state it plainly:

- **Tunnel routing has a wildcard.** `*.example.com` → ingress-nginx. Adding a service
  needs **no tunnel config change**.
- **DNS has no wildcard.** Every hostname needs its own **proxied CNAME** (proxied is the
  orange-cloud toggle: Cloudflare answers with its own IPs and relays the traffic) to
  `<TUNNEL_UUID>.cfargotunnel.com`, or traffic never reaches the tunnel at all. A wildcard
  DNS record can exist, but *proxying* one is an Enterprise feature, and an unproxied
  wildcard defeats the point.

Check with `dig +short random-xyz.example.com @1.1.1.1` — it should be NXDOMAIN (the DNS
answer for a name that does not exist).

### Adding a hostname

There is no DNS-as-code here; a one-shot API call is the canonical pattern. The helper
script is [`scripts/cf-dns-record.sh`](../scripts/cf-dns-record.sh):

```bash
TOKEN=$(kubectl -n cert-manager get secret cloudflare-api-token \
        -o jsonpath='{.data.api-token}' | base64 -d)
ZONE=<ZONE_ID>
TUNNEL=<TUNNEL_UUID>
HOST=myservice                      # bare subdomain, no trailing dot

curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records \
  -d "{\"type\":\"CNAME\",\"name\":\"$HOST\",\"content\":\"$TUNNEL.cfargotunnel.com\",\"proxied\":true}"

dig +short $HOST.example.com @1.1.1.1     # must return Cloudflare anycast IPs
```

Then a normal `Ingress` in-cluster with `cert-manager.io/cluster-issuer: letsencrypt-prod`.

**Always verify with `dig`.** Cloudflare's API returns `success: true` for records it
then silently refuses to publish (see below), and the failure is invisible otherwise.

### Why issue an internal Let's Encrypt cert if Cloudflare terminates?

So the same `Ingress` works whether it is reached through the tunnel or directly at
`192.168.1.200` on the LAN. One certificate, both paths, no split configuration.

## Cloudflare gotchas

**Some hostnames are silently refused.** The API returns `success: true`, the record
never publishes to the authoritative nameservers, and nothing anywhere says why. Observed
with names that read as an official property of a product — e.g. `argocd.<domain>` and
`n8n-community.<domain>` both blocked, while `gitops`, `argo2`, `n8n-comm`, `n8n-oss` and
`community-n8n` all published instantly against the same tunnel.

It is not propagation: a control record created five minutes *later* resolved while the
blocked one still did not. Do not fight it — probe a couple of alternatives and move on.
Worth remembering for any hostname that pairs a product name with an official-sounding
word.

**Universal SSL** (the free edge certificate every Cloudflare domain gets) **covers one
label only.** `*.example.com` is covered; `hooks.service.example.com` is not, and fails
TLS at the edge without Advanced Certificate Manager (a paid add-on). Keep every hostname
single-level.

**A failed record is worse than no record**, because the Ingress and certificate both
look healthy. `dig` is the only honest check.
