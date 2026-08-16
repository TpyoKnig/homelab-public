#!/bin/bash
# cf-dns-record.sh — add a proxied CNAME for a new tunnelled hostname.
#
#   ./cf-dns-record.sh myservice
#
# The tunnel already has a wildcard ingress rule (*.example.com → ingress-nginx),
# so adding a service needs NO tunnel config change. But DNS has no wildcard:
# each hostname needs its own proxied CNAME or traffic never reaches the tunnel.
#
# Reuses the same Cloudflare token cert-manager holds (scope Zone:DNS:Edit).
set -euo pipefail

HOST=${1:?usage: cf-dns-record.sh <bare-subdomain>}
ZONE=${CF_ZONE_ID:?set CF_ZONE_ID}
TUNNEL=${CF_TUNNEL_UUID:?set CF_TUNNEL_UUID}
DOMAIN=${CF_DOMAIN:-example.com}

TOKEN=${CF_API_TOKEN:-$(kubectl -n cert-manager get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d)}

curl -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -d "{\"type\":\"CNAME\",\"name\":\"$HOST\",\"content\":\"$TUNNEL.cfargotunnel.com\",\"proxied\":true}" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["success"], r.get("errors"))'

# ALWAYS verify. Cloudflare returns success:true for records it then silently
# refuses to publish to the authoritative nameservers — observed with names that
# read as an official property of a product. Nothing anywhere reports it, and the
# Ingress and certificate both look perfectly healthy.
echo "--- dig check (must return Cloudflare anycast IPs, not empty) ---"
sleep 5
dig +short "$HOST.$DOMAIN" @1.1.1.1
