# Three boxes, a Pi, and a Kubernetes cluster that runs my automation

*A build log: from haggling over a lot of used office PCs to a 3-node HA Talos cluster
running n8n, with Prometheus and git deliberately living outside it.*

This is the narrative version. The [reference docs](README.md) are the how-to — every
command, every config, in order. This is why it looks the way it does, and what went
wrong on the way there.

---

## 1. Why bother

I wanted a place to run automation — n8n mostly, plus whatever else — that wasn't a
monthly bill and wasn't on someone else's roadmap. Two constraints made every later
decision for me:

- **Nothing inbound.** No port forward, no LAN IP in public DNS. If the only way in is a
  tunnel I opened from the inside, the attack surface is a Cloudflare hostname, not my
  router.
- **The cluster is not precious.** I should be able to wipe all three machines and get
  everything back from git. That means git can't live *in* the cluster, and neither can
  the monitoring that would tell me the cluster is sick.

Both of those sound obvious written down. They are also the two things I'd have gotten
wrong if I'd started by installing Kubernetes and figuring out the rest later.

## 2. Buying the hardware

I did not buy these on Amazon. I found a seller on eBay listing Lenovo ThinkCentre M920q
Tinys one at a time — i5-8500T, 16 GB, 256 GB NVMe — and messaged them asking about a
bundle. It turned out they had a lot more than three in stock and were trickling out
inventory. We went back and forth about RAM, and I ended up with a custom listing: **three
machines, i5-8500T vPro, 2×16 GB, 256 GB NVMe, $450**.

Then shipping was $180, which is a genuinely funny line item on a $450 order, and the
total landed at **$672.53** delivered. Three HA nodes, 96 GB of RAM, for less than one
mid-range GPU.

If you're shopping for this: message the seller. Every used-enterprise-hardware storefront
is one person with a shelf, and a lot of three is worth a conversation to them. Ask for
the RAM you want rather than buying sticks separately — mine swapped to 2×16 GB per box
before shipping, which in 2026 is worth more than it sounds like (see §13).

**What actually matters in the spec**, and what doesn't:

| Matters | Why |
| --- | --- |
| Wired NIC | The control-plane VIP and Cilium's L2 announcements need a real L2 segment. No Wi-Fi. |
| NVMe big enough for OS **and** Longhorn | Replica data lives on the same disk as Talos. 256 GB is tight but fine. |
| BIOS with "After Power Loss: Last State" | Otherwise every outage is a trip to the closet with a keyboard. |
| vPro | Nice, not required. I've used it once. |

Single NIC, no bonding, no redundant power. That's a lab, and the right move is to accept
it consciously rather than discover it during an outage.

The rest of the shopping list came in over the following three weeks: a UniFi UNAS 4
four-bay NAS at $451.76 delivered, two M.2 trays and a pair of Samsung PM9A1 512 GB drives
for its cache at $193.23, and a Raspberry Pi 5 8 GB I'd bought off the shelf at Micro
Center in early 2025 — back when an 8 GB Pi 5 was $80 and nobody thought that was
remarkable.

## 3. The drives, which took two tries

I bought three HGST Ultrastar 8 TB enterprise drives from an eBay storefront — $125 each,
$414.55 with shipping and tax. They arrived four days later.

**All three were dead.** Not degraded, not throwing SMART warnings — none of them spun up
at all. I tested each one two ways, through a USB dock and directly on a SATA port, and
got nothing from any of them. Three for three is not bad luck, it's a seller who never
plugged them in.

The seller took the return without much argument, and eBay refunded me on August 11th.
Then I bought **three used 8 TB HGSTs from someone on Reddit for $414** — the same drives
for the same money, from a stranger with a post history instead of a storefront with a
returns policy. Those work.

I don't have a tidy lesson here. Recertified-from-a-store was the *safe* option on paper
and it was the one that failed. What I'd actually change: test drives the day they arrive,
before the return window is a factor, and budget the time to do it twice.

## 4. Day 0: the boring hour that saves a weekend

Before writing a single line of config, three things:

**BIOS, on each box.** Secure Boot off. Boot order USB then NVMe. After Power Loss →
Last State. Wake-on-LAN on. That last pair is what makes the lab headless.

**An IP plan, written down before it's needed.** Static block excluded from DHCP, so
nothing else can grab those addresses:

| Role | Address |
| --- | --- |
| Control-plane VIP | `192.168.1.110` |
| node-1/2/3 | `.101` – `.103` |
| Ops host (Pi 5) | `.100` — deliberately outside the cluster |
| NAS | `.239` |
| Cilium LoadBalancer pool | `.200 – .230` |

The VIP is the important one. It floats across all three control-plane nodes, so
`kubeconfig` and `talosconfig` point at one address that survives any single node dying.

**Capture the NIC and disk names before writing machine configs.** Boot the installer,
let the node sit in maintenance mode, and ask it:

```bash
talosctl -n "$MAINT_IP" get links --insecure    # NIC name and driver
talosctl -n "$MAINT_IP" get disks --insecure    # /dev/nvme0n1, etc.
```

Then select the interface by **driver**, not name:

```yaml
network:
  interfaces:
    - deviceSelector:
        driver: e1000e
```

The same hardware surfaces as `enp0s31f6`, `eno2` or `eth0` depending on firmware mood.
Selecting by driver is identical across all three boxes and survives a BIOS update. This
also bit me later in a place I didn't expect — see §12.

Full detail: [docs/01-hardware-and-network.md](docs/01-hardware-and-network.md).

## 5. Talos, because there's nothing to log into

I run [Talos Linux](https://www.talos.dev/) rather than Ubuntu-plus-kubeadm. There is no
shell, no SSH, no package manager — the whole OS is an immutable image and the only
interface is an API. You cannot fix it by hand, which means you cannot *break* it by hand,
which means the machine in the closet is the same machine described in git.

Two build-time details:

**System extensions must be in the install image, not just the ISO.** `iscsi-tools` and
`util-linux-tools` (both needed by Longhorn) get baked into an [Image
Factory](https://factory.talos.dev/) schematic, and that schematic ID goes in the *install*
image reference. Put them only in the boot ISO and they vanish the moment the node boots
from disk.

**Disable the CNI and kube-proxy before bootstrap**, because Cilium replaces both:

```yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
```

On Talos v1.13 that key is `cluster.proxy.disabled`. Plenty of older examples show
`cluster.network.proxy.disabled` — v1.13 **silently ignores** it, and you get a
kube-proxy DaemonSet fighting Cilium for the same job with no error anywhere. Both keys
must be right *before* bootstrap; changing them afterwards is a rebuild.

The cluster itself is an OpenTofu root: secrets → machine configs → apply to three nodes →
bootstrap exactly one of them → pull kubeconfig. `tofu apply` and go make coffee.

Full detail: [docs/02-talos-cluster.md](docs/02-talos-cluster.md).

## 6. The platform layer

Everything below is installed before GitOps takes over, because Argo CD needs a cluster
that already has networking, storage and TLS.

- **Cilium** as CNI with `kubeProxyReplacement: true`. It also does LoadBalancer IPAM and
  L2 announcements, so there's no MetalLB — one fewer moving part, and Hubble gives me
  flow visibility I'd otherwise have to bolt on.
- **Longhorn** for replicated block storage across the three node NVMes. Survives one node
  down. The NAS is the *cold* copy, not the primary — Longhorn replicates hot, the NAS
  holds what's left if a pool-wide problem takes all three replicas.
- **ingress-nginx** on `192.168.1.200`, **cert-manager** with a Let's Encrypt DNS-01
  issuer, **KEDA** for queue-depth autoscaling, **metrics-server**.

Full detail: [docs/03-platform-layer.md](docs/03-platform-layer.md).

## 7. Cloudflare: two tunnels, zero open ports

Every external hostname is a proxied CNAME to `<TUNNEL_UUID>.cfargotunnel.com`. Nothing
listens on my WAN address. `cloudflared` runs *inside* the cluster and dials out.

There are **two** tunnels, deliberately:

```
cluster tunnel  → *.example.com        (n8n, searxng, argo…)
pi-ops tunnel   → git.example.com      (Forgejo, on the Pi)
```

If the cluster is gone, git — the source of truth I'd rebuild it from — is still
reachable. One tunnel would have made that a circular dependency, and I'd only have found
out at exactly the wrong moment.

TLS is a real Let's Encrypt certificate issued in-cluster via DNS-01, even though
Cloudflare terminates at the edge. That means the same `Ingress` works through the tunnel
*and* directly at `192.168.1.200` on the LAN. One certificate, both paths.

Full detail: [docs/04-cloudflare.md](docs/04-cloudflare.md).

## 8. GitOps, and why git isn't in the cluster

**Forgejo runs on the Pi**, not in Kubernetes. Argo CD runs in the cluster and pulls from
the Pi. Secrets are SOPS-encrypted with an age key, committed, and decrypted in-cluster by
sops-secrets-operator.

The recovery story is the whole point: rebuild the three nodes from OpenTofu, run one
bootstrap script, and Argo pulls everything else back. The only thing I must protect
off-site is the age key and the Forgejo repo — both of which live on a $80 computer that
draws 5 watts and is not part of the thing it's backing up.

Apps take one of three shapes depending on what upstream publishes: a Helm chart becomes a
two-source Application (chart + a `ref: values` pointing at my repo), raw YAML becomes a
single-source `path:`, and a Terraform module becomes a `Terraform` CR run by
tofu-controller. That's the whole taxonomy — [the README explains the layout](README.md#how-iac-is-organised).

Full detail: [docs/05-gitops.md](docs/05-gitops.md).

## 9. Observability on the Pi, because you don't monitor a thing with itself

Prometheus, Loki, Tempo and Grafana all run on the Raspberry Pi 5, in Docker Compose,
outside the cluster.

This is the decision people push back on, and it's the one I'd defend hardest. If
Prometheus is a pod, then "the cluster is down" and "I can't see anything" are the same
event. Scraping from outside costs me a little convenience — no automatic
ServiceMonitor discovery, some manual scrape config — and buys me a monitoring stack that
is loudest exactly when the cluster is quietest.

The Pi also runs Forgejo, its Actions runner, and the backup cron jobs. It is the single
most load-bearing $80 in the lab, which is why it has its own tunnel, its own backups, and
a documented rebuild path.

Full detail: [docs/06-ops-host.md](docs/06-ops-host.md).

## 10. The thing it was all for

**n8n, in queue mode.** A main process for the editor, separate workers, CloudNativePG
for Postgres, Valkey for the queue, and KEDA scaling workers on queue depth rather than
CPU. Binary data goes to an RWX volume on the NAS so any worker can read what any other
worker wrote.

It's deployed as a **Terraform module**, not a Helm chart — my own
[`terraform-kubernetes-n8n`](https://github.com/TpyoKnig/terraform-kubernetes-n8n), run by
tofu-controller from inside the cluster. Version bumps are a one-line git commit.

**The ingress is split in two**, and this is the part I'd have gotten wrong without
hitting it: n8n Community has no SSO. Authentication therefore has to live at the ingress
— except webhooks are called by machines that can't authenticate. One hostname can't serve
both an allowlisted editor and open webhook endpoints, so there are two:

```
n8n.example.com          editor  → IP allowlist at the ingress
hooks.example.com        webhooks → open, no auth annotations
```

Two Ingress objects, one Service. With `N8N_PROXY_HOPS=2` so n8n sees the real client IP
through both Cloudflare and nginx.

**The AI Assistant, with somewhere to actually run code.** n8n's assistant can write and
execute code — but only if you give it a sandbox. Without one it loads, chats happily, and
every execution fails.

That's [`n8n-sandbox-service`](https://github.com/TpyoKnig/n8n-sandbox-service): an API
Deployment plus a runner StatefulSet, talking gRPC over mTLS, spawning one throwaway
Debian container per session.

```
n8n-main ──X-Api-Key──> sandbox-api ──gRPC + mTLS──> runner ──> sandbox containers
```

On Talos it runs in **`dind` mode**, and that's not a preference. The chart's default
`sysbox` mode needs a modified container runtime on the node — which is precisely the
thing an immutable-rootfs distro won't let you do. `dind` exists for this case. If you're
on Talos, use [tag `0.0.1`](https://github.com/TpyoKnig/n8n-sandbox-service/tree/0.0.1);
the chart is published by git tag only, so pin the tag or the commit.

The env var names cost me an evening. n8n's docs name
`N8N_INSTANCE_AI_SANDBOX_API_URL` / `_API_KEY`. **Those two strings appear in no shipped
build.** The code reads `N8N_SANDBOX_SERVICE_URL` and `N8N_SANDBOX_SERVICE_API_KEY`.
Nothing errors on an env var n8n doesn't read — you just get an assistant that loads and
can't execute anything, silently.

**SearXNG** is self-hosted metasearch, and doubles as the assistant's search backend.
Worth knowing: n8n resolves search providers in a fixed order, and setting a Brave key
takes SearXNG *out* of the path entirely, silently.

**PR-Agent** does AI code review on every Forgejo PR — which brings us to what this is
actually like to use.

## 11. The payoff: everything is a pull request

This is the part that justifies the setup cost, and it's hard to appreciate until it's
running.

I don't `kubectl apply` anything. I don't SSH anywhere — there's nowhere to SSH *to*. A
change to any workload in this lab looks like this:

1. **Branch and edit a file** — a Helm values file, a `.tf` version pin, an env var.
2. **Open a PR** in Forgejo. PR-Agent reviews it automatically and comments: a description,
   a walkthrough, suggestions. An AI reviewer on a homelab PR sounds absurd until it catches
   an indentation error in a values file at 11pm.
3. **Merge.** That's the last manual step.
4. **Argo CD notices** within a couple of minutes and reconciles the cluster to match. For
   the n8n module, tofu-controller runs the plan and applies it. Nothing else happens by
   hand.

The properties that fall out of that:

- **The cluster can't drift.** `selfHeal: true` means anything changed out-of-band gets
  reverted to what git says. If I hand-patch something in a hurry, Argo undoes it — which
  is annoying exactly once, and then it's a feature.
- **Every change has a diff, an author and a timestamp.** "What did I break last Tuesday"
  is `git log`, not memory.
- **Rollback is `git revert`.** Not a restore, not a snapshot — the same mechanism as the
  change itself, which means I've already tested it every time I merge anything.
- **Rebuilding is the same operation as deploying.** Bare metal to full stack is
  `tofu apply`, one bootstrap script, and then Argo pulls back all 37 applications
  unattended. That path isn't theoretical — it's the same path every routine change takes,
  so it can't rot.
- **Upgrades are a version string.** Bumping n8n is editing one line and merging the PR.

The cost of getting here was a few weekends and the gotchas in the next section. The
return is that the lab now takes near-zero operational attention, and the parts of it I
touch weekly are the parts I *want* to touch — the workflows, not the infrastructure.

## 12. What actually broke

The useful part.

**Nineteen nights of etcd snapshots that never happened.** The cron script called
`talosctl` bare. Cron's `PATH` doesn't include `/usr/local/bin`. It failed instantly,
every night, into a log nobody read, and the backup directory just quietly stopped
growing. Use absolute paths in cron scripts. Better: make the script assert that the file
it just wrote exists and is a plausible size, because *a backup job that stops silently is
the same as no backup*.

**My own router was eating DNS-01 validation.** cert-manager's propagation self-check
would stall forever on `_acme-challenge` TXT lookups while every other thing on the
network looked perfectly healthy. Some consumer routers — UniFi among them — hijack
outbound UDP/53 and answer for it. The fix that survives firmware updates is to make
CoreDNS forward over DNS-over-TLS, so the queries are in a TLS session the router can't
open.

**Cloudflare silently refuses some hostnames.** The API returns `success: true`. The
record never publishes. Nothing, anywhere, says why. `argocd.<domain>` and
`n8n-community.<domain>` were both blocked; `gitops`, `argo2`, `n8n-comm`, `n8n-oss` and
`community-n8n` all published instantly against the same tunnel. It isn't propagation — a
control record created five minutes *later* resolved while the blocked one still didn't.
The lesson isn't "fight it", it's **always verify with `dig`**, because a failed record
looks identical to a working one from inside the cluster: the Ingress is healthy, the
certificate is valid, and the hostname simply doesn't exist.

**Universal SSL covers one label.** `hooks.example.com` is covered.
`hooks.service.example.com` is not, and fails TLS at the edge. Keep every hostname
single-level unless you're paying for Advanced Certificate Manager.

**An EPERM that wasn't a network policy.** Argo's repo-server OOMed pulling a large chart
— 512Mi default limit, exit 137, CrashLoopBackOff. The app-controller then reported
`dial tcp <svc-ip>:8081: connect: operation not permitted`, which reads *exactly* like a
Cilium NetworkPolicy denial. It wasn't. There were simply no listeners behind the Service.
I spent an evening auditing policies that were fine. Pin the repo-server's memory to
`limits: {memory: 2Gi}` and move on.

**`^enp.*` vs `^eno.*`.** Cilium's L2 announcement policy matches interfaces by regex, and
every example on the internet uses `^enp.*`. These boxes present `eno2`. Announcements
just… don't happen, and LoadBalancer IPs sit there unreachable with nothing in any log
saying the policy matched zero interfaces.

**`talosctl upgrade-k8s` hangs on the VIP.** The gRPC session goes stale when the API
server behind the VIP bounces, and talosctl hangs on the final kubelet-restart check even
though the upgrade already completed. Point `talosconfig` at a specific node IP for
upgrades.

**OpenTofu and Terraform don't share a module registry.** I publish my n8n module to the
Terraform registry, so `source = "TpyoKnig/n8n/kubernetes"` works under Terraform and
fails with `Module not found` under OpenTofu — different index, same syntax. Under
OpenTofu you need the `git::…?ref=` form.

**The NAS wouldn't do NFSv4.** No export carried `fsid=0`, so there's no v4 pseudo-root
and only v3 mounts work. Longhorn's NFS backup driver mounts `-t nfs4` with no fallback
and no override. The backup target had to become CIFS/SMB instead. Verify with
`showmount -e` and a manual mount at each version *before* designing around an appliance.

## 13. What it cost — and what it would cost you today

| Item | Paid |
| --- | --- |
| 3× ThinkCentre M920q (i5-8500T, 32 GB, 256 GB NVMe) | $672.53 |
| UniFi UNAS 4 | $451.76 |
| 2× M.2 tray + 2× Samsung PM9A1 512 GB (NAS cache) | $193.23 |
| 3× HGST 8 TB, used, from Reddit | $414.00 |
| 3× HGST 8 TB from an eBay storefront | ~~$414.55~~ refunded — all three DOA |
| **Total** | **$1,731.52** |

Plus the Pi 5, bought at Micro Center in early 2025 for $80.

**The cluster itself was $672.53.** Everything else is storage.

Now the honest part: **you cannot reproduce this at these prices right now.** The AI
memory crunch has been eating consumer DRAM and NAND all year. A 32 GB DDR4 kit that was
around $50 in early 2025 runs [$250–350 today](https://www.tomshardware.com/pc-components/ram/ram-price-index-2026-lowest-price-on-ddr5-and-ddr4-memory-of-all-capacities).
The Pi 5 is the clearest case: I paid $80 for mine at Micro Center in early 2025, and
[Raspberry Pi has raised prices twice
since](https://www.raspberrypi.com/news/more-memory-driven-price-rises/) — the same 8 GB
board is $175 from CanaKit and north of $200 on Amazon as I write this. Same part, same
shelf, more than double the money in eighteen months. 1 TB NVMe contract prices
[more than doubled across the first half of 2026](https://www.tomshardware.com/pc-components/ssds/ssd-price-tracking-2026-lowest-price-on-every-m-2-ssd).

Which changes the advice, not the architecture:

- **Buy used machines with the RAM already in them.** The 96 GB in my three boxes would
  cost more than the boxes did if I bought it as sticks today. This is the single biggest
  saving available and it's pure timing luck.
- **Three cheap nodes still beat one good one.** HA isn't the point — being able to
  reboot a node during the day is.
- **Used enterprise drives from a person beat recertified drives from a storefront**, at
  least this once. Test them the day they land.

## What I'd do differently

Not much structurally — the two constraints from §1 held up. Three smaller things:

1. **Write the backup verification before the backup.** Nineteen nights.
2. **Check the NAS's NFS version before designing storage around it**, not after.
3. **Buy the RAM in 2025.** Can't help you there.

---

**The full build guide** — every command in order, bare metal to running workloads — is
[BOOTSTRAP.md](BOOTSTRAP.md). The per-subsystem detail is in [docs/](docs/). All of it is
sanitised: `example.com`, `192.168.1.0/24`, and no live keys. The architecture and the
gotchas are real.
