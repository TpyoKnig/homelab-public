# 10 · PR-Agent — AI code review on Forgejo

Every pull request on every Forgejo repo gets an automatic AI review comment. Nothing to
click, nothing to run.

[PR-Agent](https://github.com/The-PR-Agent/pr-agent) is the original open-source PR
reviewer. Qodo built it and handed it to a community-owned org in April 2026; it is MIT
now. The Qodo-branded product advertised today is a separate commercial thing — this is
not that, and nothing here talks to Qodo's servers. Only the model API is called.

**Why it works against Forgejo at all:** Forgejo exposes the Gitea API, and PR-Agent ships
a first-class `gitea` provider with full `/describe`, `/review`, `/improve` and `/ask`
support. No fork, no adapter, no shim.

> Image naming changed at the handover. Old images are `codiumai/pr-agent:*` and stop at
> `0.34`. Current images are `pragent/pr-agent:<version>-<target>`; the one to run is the
> `-gitea_app` variant, which is the FastAPI webhook receiver rather than the CLI. Docs
> referencing `codiumai` predate the transfer.

## Flow

```
 developer opens a PR on git.example.com
              │
 Forgejo (pi-ops)  ── webhook, POST + sha256 HMAC ──┐
              │                                     │
              ▼                                     │
 192.168.1.203:3000/api/v1/gitea_webhooks   ← Service/pr-agent-lan (Cilium LB)
              │
              ▼
 Deployment/pr-agent (ns pr-agent, 1 replica)
              │  reads the PR diff back over the LAN Forgejo API (:3001)
              │  sends diff + prompt to the model API
              ▼
 comments posted back onto the PR
```

Both hops that touch Forgejo use the **LAN** address, not the public hostname — the
traffic never leaves the house and never touches the Cloudflare tunnel.

**No ingress, no DNS record, no TLS — deliberately.** A public hostname would add
internet-facing attack surface for zero benefit. Authentication is the sha256 HMAC that
Forgejo signs each delivery with.

## What it posts

Auto-fires on pull request **opened**, **reopened** and **synchronized** (every push to an
open PR):

| Command | Result |
| --- | --- |
| `/describe` | Rewrites the PR body with a generated summary, type and file walkthrough. Original text is preserved above it under "User description" |
| `/review` | A reviewer-guide comment: effort estimate, tests, key issues |
| `/improve` | Concrete code suggestions. "No code suggestions" is a real answer, not a failure |

Push-to-branch triggers are off (`handle_push_trigger=false`), so commits outside a PR
cost nothing.

On-demand: comment `/review`, `/improve`, `/describe`, `/ask <question>` or `/help` on an
open PR.

### Comment style

Set `PR_REVIEWER__PERSISTENT_COMMENT=false` and
`PR_CODE_SUGGESTIONS__PERSISTENT_COMMENT=false`. The upstream default is "persistent" —
every run silently *edits the same comment* near the top of the thread. That reads fine
for a one-shot PR and terribly for an agent-driven branch, where after each commit you
scroll back up to find what changed. With it off, the thread is chronological: one round
per commit, top to bottom.

Two consequences: nothing is auto-collapsed or resolved (Forgejo issue comments have no
"resolve", and the gitea provider can't minimise them the way the GitHub one can), and
`PR_REVIEWER__FINAL_UPDATE_MESSAGE` becomes meaningless, so turn it off too.

### Token budget

`CONFIG__MAX_MODEL_TOKENS=200000`. The image ships `32000`, which caps **every** model
regardless of what it can actually take. A large diff gets silently pruned and the review
ends with "Additional modified files (insufficient token budget to process)" listing what
it dropped. If you see that line, raise the limit — don't shrink the PR. The log is
explicit either way: `total tokens over limit: 32000, pruning diff` versus
`total tokens under limit: 200000, returning full diff`.

## Adding a repo

**New repos: nothing to do.** Configure a Forgejo **default webhook** at admin level;
Forgejo copies it into every repository at creation time.

**Repos created before the default webhook existed** need it added once, because default
webhooks only apply at creation. Same for any repo you import or migrate later:

```bash
WHS=$(kubectl -n pr-agent get secret pr-agent-secrets \
      -o jsonpath='{.data.GITEA__WEBHOOK_SECRET}' | base64 -d)

curl -s -X POST -u "<user>:<password>" -H "Content-Type: application/json" \
  -d "{\"type\":\"gitea\",\"active\":true,\"branch_filter\":\"*\",
       \"config\":{\"url\":\"http://192.168.1.203:3000/api/v1/gitea_webhooks\",
                   \"content_type\":\"json\",\"secret\":\"${WHS}\"},
       \"events\":[\"pull_request\",\"issue_comment\"]}" \
  http://192.168.1.100:3001/api/v1/repos/<user>/<REPO>/hooks
```

`events` must include **both**: `pull_request` drives the automatic review,
`issue_comment` is what makes the `/review`-style commands work.

**Per-repo tuning** goes in a `.pr_agent.toml` at that repo's root, not in the Deployment
env (which is global). Useful keys: `[pr_reviewer] extra_instructions`, `[config] model`,
`[pr_description] publish_description_as_comment`.

## Deployment notes

| Thing | Value |
| --- | --- |
| Namespace | `pr-agent`, PSS **restricted** (runs as uid 1000; the image would otherwise run as root) |
| Image | `pragent/pr-agent:0.42.0-gitea_app`, **digest-pinned** |
| Service | `pr-agent-lan`, LoadBalancer `192.168.1.203:3000` |
| Forgejo side | the LB IP must be in `FORGEJO__webhook__ALLOWED_HOST_LIST` |
| Secrets | Forgejo PAT, webhook HMAC, model API key — all in one SopsSecret |

**Model config:** change `CONFIG__MODEL` and `CONFIG__FALLBACK_MODELS` **together**. The
image defaults to OpenAI models; if there is no OpenAI key in the cluster, a half-changed
config only fails on the retry path, which is the worst way to find out. Model names must
appear in PR-Agent's token map (`pr_agent/algo/__init__.py`) or be paired with
`config.custom_model_max_tokens`.

**Credentials:** use a scoped PAT (`write:repository`, `write:issue`, `read:user`), not an
admin token. The webhook HMAC is shared between the SopsSecret and every Forgejo webhook —
rotating means editing **both sides together**, or every delivery 401s at the signature
check.

## Troubleshooting

Nothing happens when a PR opens. Work down the chain, in decreasing order of likelihood:

1. **No webhook on that repo** — see "Adding a repo".
2. **Forgejo refused to deliver.** `docker logs <forgejo-container> --since 15m | grep -i webhook`.
   The classic is `webhook can only call allowed HTTP servers` → the LB IP is missing from
   `ALLOWED_HOST_LIST`. **A failed delivery is not retried** — fix the cause, then
   re-trigger by closing and reopening the PR or pushing another commit.
3. **PR-Agent rejected it.** `kubectl -n pr-agent logs deploy/pr-agent --since=15m`.
   `Missing signature header` / `Invalid signature` means the webhook secret drifted from
   the SopsSecret.
4. **The model call failed.** Same logs; look for `AI response` and any `Error`/`Failed`.

**Expected log noise, not failures:**

- `Error getting file: AGENTS.md, content: (404)` — PR-Agent reads `AGENTS.md` from the
  default branch as extra prompt context. Most repos don't have one, and adding one
  genuinely improves reviews.
- `Failed to get PR labels` / `Failed to get comments` — gaps in the upstream gitea
  provider. Reviews post fine regardless.

**Health check.** A `GET` on the webhook path returns 404 by design (it is POST-only), so
probes are TCP. Manual smoke test:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST -d '{}' \
  -H 'Content-Type: application/json' \
  http://192.168.1.203:3000/api/v1/gitea_webhooks
# 400 = server is up and rejecting unsigned payloads. That is the healthy answer.
```

## Cost and what was skipped

Per PR: one `/describe` + one `/review` + one `/improve` call, sized by the diff. Small
PRs are fractions of a cent; a large refactor is meaningfully more. Cheapest knobs, in
order: switch to a smaller model, or trim `pr_commands` to just `/review` in a repo-level
`.pr_agent.toml`.

Skipped deliberately: an ingress/public hostname (add only if a non-LAN git host ever
needs to reach it, and then the HMAC stops being the only guard); more than one replica
(reviews are idempotent background tasks — a restart loses at most one in-flight review);
a ServiceMonitor (no Prometheus Operator here; pod logs go to Loki like everything else).
