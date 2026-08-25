# From `docker run n8n` to a three-node cluster

If you self-host n8n, odds are it's one Docker container: SQLite in a volume, a reverse
proxy in front, updates by pulling a new image and eating the restart. That's how most of
the community runs it, it's the right way to start, and nothing here says stop.

This is the next step, for when the infrastructure becomes part of the hobby: the same
Community edition, no license, running in queue mode on a Talos Kubernetes cluster built
from three used office PCs and a Raspberry Pi: dedicated workers autoscaling on queue
depth, real Postgres, zero ports open on the router, the whole thing rebuildable from git.

Everything here is reproducible from this repo. [BOOTSTRAP.md](BOOTSTRAP.md) is every
command in order from bare metal to running workflows; [docs/](docs/) is the per-subsystem
detail. This post is the why, the cost, and the potholes.

## What changes, coming from Docker

| One container | This build |
| --- | --- |
| n8n does everything in one process | Queue mode: a main for the editor and API, workers that execute, webhook processors that receive |
| SQLite file in a volume | Postgres on CloudNativePG, storage replicated across three nodes |
| A restart drops whatever was running | Room to grow: KEDA scales workers to 10+ on queue depth; restarting the editor doesn't touch executions |
| Port forward or VPN to reach webhooks | Cloudflare tunnel dialing out; no inbound port anywhere |
| Backup is copying the volume and hoping | etcd snapshots, replicated volumes, a NAS cold copy, and the rebuild path gets exercised by every deploy |

> [!TIP]
> If the left column is doing the job, keep it. The right column is for when you want to
> own the platform too, and it costs less than one mid-range GPU.

## Why bother

I wanted somewhere to run automation, mostly n8n, that wasn't a monthly bill and wasn't
subject to somebody else's roadmap. Two constraints ended up making most of the later
decisions for me.

Nothing inbound. No port forward, no LAN address in public DNS. "Nobody would bother with
my house" stopped being true once the bothering got automated: the whole IPv4 space gets
port-scanned continuously, and AI-assisted tooling increasingly handles the follow-up too,
fingerprinting what answered, picking an exploit and trying it, at a cost per target of
roughly nothing. The reliable way out of that pipeline is to not answer at all. If the only way in
is a tunnel I opened from the inside, what's exposed is a Cloudflare hostname with
Cloudflare's bot filtering in front of it, not my router.

The cluster isn't precious. I should be able to wipe all three machines and get everything
back from git. Which means git can't live in the cluster, and neither can the monitoring
that's supposed to tell me the cluster is sick.

Both of those look obvious written down. They're also the two things I'd have gotten wrong
if I'd started by installing Kubernetes and figured out the rest afterward.

## Buying the hardware

I didn't get these from Amazon. I found a seller on eBay,
[Babboo's Bazaar](https://www.ebay.com/str/babboosbazaar), listing Lenovo ThinkCentre M920q
Tinys one at a time, i5-8500T, 16 GB, 256 GB NVMe, and messaged him about a bundle. Turned
out he had a lot more than three on the shelf and was trickling out inventory.

The quote came back as a bundle: RAM upgrades installed per box, a QA pass before anything
ships, and a PCIe riser and bracket thrown in on one of them for nothing. Worth knowing if
you plan to max these boxes: 64 GB only works on later BIOS revisions, so ask before
ordering it. $672.53 delivered with tax, for three HA nodes and 96 GB of RAM. Less than one
mid-range GPU.

> [!TIP]
> If you're shopping for this, message the seller. Every used-enterprise-hardware
> storefront is one person with a shelf, and a lot of three is worth a conversation to
> them. Mine turned into a lot more than three: I've gone back to the same store for
> multiple systems since, and my entire extended stack came from him. Ask for the RAM you
> want instead of buying sticks separately, seller-installed upgrades beat the parts
> market by a margin that no longer exists anywhere in 2026.

What actually matters in the spec is shorter than you'd think. A wired NIC, because the
control-plane VIP and Cilium's L2 announcements need a real L2 segment and Wi-Fi won't do.
An NVMe big enough for the OS and Longhorn both, since replica data lives on the same disk
as Talos (256 GB is tight but fine). And a BIOS that can be told to power back on after an
outage, otherwise every power blip is a trip to the closet with a keyboard. vPro is nice.
I've used it once.

> [!NOTE]
> Single NIC, no bonding, no redundant power. That's a lab, and the right move is to
> accept that consciously rather than discover it during an outage.

The rest of the list came in over the next three weeks. A UniFi UNAS 4 four-bay NAS at
$451.76 delivered, two M.2 trays and a pair of Samsung PM9A1 512 GB drives for its cache at
$193.23, and a Raspberry Pi 5 8 GB I'd picked up at Micro Center in early 2025, back when
an 8 GB Pi 5 was $80 and nobody thought that was worth mentioning.

## The drives took two tries

I bought four HGST Ultrastar 8 TB enterprise drives from an eBay storefront, $414.55 with
shipping and tax. They showed up five days later.

All four were dead. Not degraded, not throwing SMART warnings, none of them spun up at
all. I tested each one two ways, through a USB dock and directly on a SATA port, and got
nothing from any of them. Four for four isn't bad luck, it's a seller who never plugged
them in.

The refund was its own project. The seller's answer was "just send it back", and after I
did, no refund came. I filed a case with eBay, waited the three business days they ask for,
and then had to escalate a second time before the money actually moved, on August 11th.
Budget for that too: a dead-on-arrival return isn't one errand, it's a case you have to
keep pushing.

Then I bought four used 8 TB HGSTs off someone on Reddit for $414, same drives, same
money, from a stranger with a post history instead of a storefront with a returns policy.
Those work.

There isn't a tidy lesson in that. Recertified-from-a-store was the safe option on paper
and it's the one that failed.

> [!TIP]
> What I'd actually change is testing drives the day they land, while the return window is
> still comfortable, and budgeting the time to do it twice.

## Day 0, the boring hour that saves a weekend

Before writing any config, three things.

BIOS on each box: Secure Boot off, boot order USB then NVMe, After Power Loss set to Last
State, Wake-on-LAN on. That last pair is what makes the lab headless.

An IP plan, written down before it's needed, with the static block excluded from DHCP so
nothing else can grab those addresses:

| Role | Address |
| --- | --- |
| Control-plane VIP | `192.168.1.110` |
| node-1/2/3 | `.101` to `.103` |
| Ops host (Pi 5) | `.100`, deliberately outside the cluster |
| NAS | `.239` |
| Cilium LoadBalancer pool | `.200` to `.230` |

The VIP is the one that matters. It floats across all three control-plane nodes, so
`kubeconfig` and `talosconfig` point at a single address that survives any one node dying.

Then capture the NIC and disk names before writing machine configs. Boot the installer,
let the node sit in maintenance mode on a DHCP lease, and ask it:

```bash
talosctl -n "$MAINT_IP" get links --insecure    # NIC name and driver
talosctl -n "$MAINT_IP" get disks --insecure    # /dev/nvme0n1, etc.
```

Then select the interface by driver, not by name:

```yaml
network:
  interfaces:
    - deviceSelector:
        driver: e1000e
```

The same hardware shows up as `enp0s31f6`, `eno2` or `eth0` depending on firmware mood.
Selecting by driver is identical across all three boxes and survives a firmware update. The
interface name comes back to bite me later in a place I didn't expect, see the Cilium regex
below.

Detail: [docs/01-hardware-and-network.md](docs/01-hardware-and-network.md).

## Talos, because there's nothing to log into

I run [Talos Linux](https://www.talos.dev/) instead of Ubuntu plus kubeadm. No shell, no
SSH, no package manager, the whole OS is an immutable image and the only interface is an
API. You can't fix it by hand, which means you can't break it by hand either, which means
the machine in the closet is the machine described in git.

Two things to get right at build time.

> [!WARNING]
> System extensions have to be in the install image, not just the ISO. `iscsi-tools` and
> `util-linux-tools` are both needed by Longhorn, they get baked into an [Image
> Factory](https://factory.talos.dev/) schematic, and that schematic ID belongs in the
> *install* image reference. Put them only in the boot ISO and they disappear the moment
> the node boots off disk.

Disable the CNI and kube-proxy before bootstrap, since Cilium replaces both:

```yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
```

On Talos v1.13 that key is `cluster.proxy.disabled`. Plenty of older examples show
`cluster.network.proxy.disabled`, which v1.13 silently ignores, and you end up with a
kube-proxy DaemonSet fighting Cilium over the same job with nothing in any log saying so.

> [!CAUTION]
> Both keys have to be right before bootstrap. Changing them afterward is a rebuild.

The cluster itself is an OpenTofu root: secrets, machine configs, apply to three nodes,
bootstrap exactly one of them, pull kubeconfig. `tofu apply` and go make coffee.

Detail: [docs/02-talos-cluster.md](docs/02-talos-cluster.md).

## The platform layer

This all goes on before GitOps takes over, because Argo CD needs a cluster that already has
networking, storage and TLS.

Cilium is the CNI with `kubeProxyReplacement: true`, and it also handles LoadBalancer IPAM
and L2 announcements, so there's no MetalLB. One less moving part, plus Hubble gives me
flow visibility I'd otherwise have to bolt on separately.

Longhorn does replicated block storage across the three node NVMes and survives one node
going down. The NAS is the cold copy, not the primary: Longhorn replicates hot across the
nodes, the NAS holds what's left if something takes out all three replicas at once.

Then ingress-nginx on `192.168.1.200`, cert-manager with a Let's Encrypt DNS-01
ClusterIssuer, KEDA for queue-depth autoscaling, and metrics-server.

Detail: [docs/03-platform-layer.md](docs/03-platform-layer.md).

## Cloudflare, two tunnels and no open ports

Every external hostname is a proxied CNAME to `<TUNNEL_UUID>.cfargotunnel.com`. Nothing
listens on my WAN address at all. `cloudflared` runs inside the cluster and dials out.

There are two tunnels on purpose:

```
cluster tunnel  ->  *.example.com      (n8n, searxng, argo)
pi-ops tunnel   ->  git.example.com    (Forgejo, on the Pi)
```

> [!NOTE]
> If the cluster is gone, git is still reachable, and git is what I'd rebuild the cluster
> from. One tunnel would have made that circular, and I'd have found out at exactly the
> wrong moment.

TLS is a real Let's Encrypt cert issued in-cluster over DNS-01, even though Cloudflare
terminates at the edge. Same `Ingress` works through the tunnel and directly at
`192.168.1.200` on the LAN. One cert, both paths, no split config.

Detail: [docs/04-cloudflare.md](docs/04-cloudflare.md).

## GitOps, and why git isn't in the cluster

Forgejo runs on the Pi, not in Kubernetes. Argo CD runs in the cluster and pulls from the
Pi. Secrets are SOPS-encrypted with an age key, committed, and decrypted in-cluster by
sops-secrets-operator.

The recovery story is the entire point. Rebuild three nodes from OpenTofu, run one bootstrap
script, and Argo pulls back everything else. The only things I have to protect off-site are
the age key and the Forgejo repo, and both of those live on a single-board computer that
cost less than a tenth of the cluster and isn't part of the thing it's backing up.

Apps take one of three shapes depending on what upstream actually publishes. A Helm chart
becomes a two-source Application, chart plus a `ref: values` pointing at my repo. Raw YAML
becomes a single-source `path:`. A Terraform module becomes a `Terraform` CR run by
tofu-controller. That's the whole taxonomy, and the
[README lays out the directories](README.md#how-iac-is-organised).

Detail: [docs/05-gitops.md](docs/05-gitops.md).

## Monitoring lives on the Pi

Prometheus, Loki, Tempo and Grafana all run on the Raspberry Pi 5 in a compose stack,
outside the cluster.

This is the decision people push back on and it's the one I'd defend hardest. If Prometheus
is a pod, then "the cluster is down" and "I can't see anything" are the same event. Scraping
from outside costs me some convenience, no automatic ServiceMonitor discovery and some
scrape config written by hand, and buys me a monitoring stack that's loudest exactly when
the cluster is quietest.

The Pi also runs Forgejo, its Actions runner, and the backup cron jobs. It's the $80 box
the whole lab depends on, which is why it gets its own tunnel, its own backups, and a
documented rebuild path.

Detail: [docs/06-ops-host.md](docs/06-ops-host.md).

## The thing it was all for

n8n runs in queue mode: a main process for the editor, separate workers, CloudNativePG for
Postgres, Valkey for the queue, and KEDA scaling workers on queue depth instead of CPU.
Binary data goes to an RWX volume on the NAS so any worker can read what any other worker
wrote.

It's deployed from my own Terraform module,
[terraform-kubernetes-n8n](https://github.com/TpyoKnig/terraform-kubernetes-n8n), run by
tofu-controller from inside the cluster. Version bumps are a one-line commit.

n8n does publish [an official
chart](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n) and it handles queue
mode, workers and KEDA perfectly well, so this isn't a gap I was filling. The difference is
that the chart wants Postgres and Redis to already exist, so you're wiring up three things
and keeping them in step. The module stands up CloudNativePG and Valkey alongside n8n, so
the whole workload is one `apply`. If you already run Postgres and Redis in your cluster,
use the chart.

> [!IMPORTANT]
> The ingress is split in two, and this is the part I'd have gotten wrong without running
> into it. n8n Community has no SSO, so authentication has to live at the ingress. Except
> webhooks are called by machines that can't authenticate. One hostname can't serve both an
> allowlisted editor and open webhook endpoints, so there are two:
>
> ```
> n8n.example.com      editor, IP allowlist at the ingress
> hooks.example.com    webhooks, open, no auth annotations
> ```

Two Ingress objects, one Service, with `N8N_PROXY_HOPS=2` so n8n sees the real client IP
through both Cloudflare and nginx.

### The AI Assistant needs somewhere to run code

n8n's assistant can write and execute code, but only if you give it a sandbox. Without one
it loads, chats happily, and every execution fails.

That's what [n8n-sandbox-service](https://github.com/n8n-io/n8n-sandbox-service) is: an
API Deployment plus a runner StatefulSet, talking gRPC over mTLS, spawning one throwaway
Debian container per session.

```
n8n-main --X-Api-Key--> sandbox-api --gRPC + mTLS--> runner --> sandbox containers
```

Talos can't run the chart's preferred `sysbox` isolation, and that's not a preference:
sysbox needs a modified container runtime on the node, which is precisely the thing an
immutable-rootfs distro won't let you do. When I built this, the workaround was a pinned
tag of my own repo running plain Docker-in-Docker. That's history now: the project moved
upstream to n8n, and since chart `0.4.0`
([PR #126](https://github.com/n8n-io/n8n-sandbox-service/pull/126)) Talos is supported
out of the box with `runner.isolation: privileged` plus
`runner.acknowledgePrivileged: true`. The render fails until you acknowledge the weaker
security boundary, which is the right kind of friction. No tag pin needed anymore, and
the upstream chart is what this lab runs today.

Wiring n8n to it is four env vars on the main pods:

```
N8N_INSTANCE_AI_SANDBOX_ENABLED=true
N8N_INSTANCE_AI_SANDBOX_PROVIDER=n8n-sandbox
N8N_SANDBOX_SERVICE_URL=http://<sandbox-api service>:8080
N8N_SANDBOX_SERVICE_API_KEY=<one of the service's api-keys values>
```

> [!WARNING]
> Get the last two names exactly right. n8n doesn't error on an env var it never reads, so
> a misspelled name produces an assistant that loads and can't execute anything, quietly.

SearXNG is self-hosted metasearch and doubles as the assistant's search backend.

> [!WARNING]
> Worth knowing that n8n resolves search providers in a fixed order, and setting a Brave
> key takes SearXNG out of the path entirely without saying so.

PR-Agent does AI code review on every Forgejo PR, which is a good place to explain what
this is actually like to use.

## Everything is a pull request

This is the part that pays back the setup cost, and it's hard to appreciate until it's
running.

I don't `kubectl apply` anything. I don't SSH anywhere, there's nowhere to SSH to. A change
to any workload in the lab looks like this:

1. Branch and edit a file. A Helm values file, a `.tf` version pin, an env var.
2. Open a PR in Forgejo. PR-Agent reviews it automatically and comments with a description,
   a walkthrough, and suggestions. An AI reviewer on a homelab PR sounds ridiculous right
   up until it catches an indentation error in a values file at 11pm.
3. Merge. That's the last manual step.
4. Argo CD picks it up within a couple of minutes and reconciles the cluster to match. For
   the n8n module, tofu-controller runs the plan and applies it.

What falls out of that is the actual payoff. The cluster can't drift, because `selfHeal:
true` reverts anything changed out of band, which is annoying exactly once and then it's a
feature. Every change has a diff, an author and a timestamp, so "what did I break last
Tuesday" is `git log` and not memory. Rollback is `git revert`, not a restore and not a
snapshot, which means I've tested the rollback path every single time I merge anything.
Upgrades are a version string.

And rebuilding is the same operation as deploying. Bare metal to full stack is `tofu apply`,
one bootstrap script, then Argo pulling every application back unattended. That path isn't
theoretical, it's the same path every routine change takes, so it can't quietly rot the way
a disaster-recovery runbook does.

The cost of getting here was a few weekends plus the gotchas below. What I get back is a lab
that needs near-zero operational attention, where the parts I touch weekly are the parts I
want to touch. The workflows, not the infrastructure.

## What actually broke

The useful part.

**Nineteen nights of etcd snapshots that never happened.** The cron script called `talosctl`
bare. Cron's `PATH` doesn't include `/usr/local/bin`. It failed instantly, every night, into
a log nobody was reading, and the backup directory just quietly stopped growing. Use
absolute paths in cron scripts, and better, make the script assert that the file it just
wrote exists and is a plausible size. A backup job that stops silently is the same as no
backup.

**My own router was eating DNS-01 validation.** cert-manager's propagation self-check would
stall forever on `_acme-challenge` TXT lookups while everything else on the network looked
perfectly healthy. Some consumer routers hijack outbound UDP/53 and answer for it, UniFi
among them. The fix that survives firmware updates is making CoreDNS forward over
DNS-over-TLS, so the queries sit inside a TLS session the router can't open.

**Cloudflare silently refuses some hostnames.** The API returns `success: true`, the record
never publishes, and nothing anywhere says why. `argocd.<domain>` and `n8n-community.<domain>`
were both blocked, while `gitops`, `argo2`, `n8n-comm`, `n8n-oss` and `community-n8n` all
published instantly against the same tunnel. It isn't propagation either: a control record
created five minutes later resolved while the blocked one still didn't. Don't fight it,
just probe a couple of alternatives. The real lesson is to always verify with `dig`, because
from inside the cluster a failed record looks identical to a working one. Ingress healthy,
certificate valid, hostname simply doesn't exist.

**Universal SSL only covers one label.** `hooks.example.com` is covered.
`hooks.service.example.com` isn't, and fails TLS at the edge. Keep every hostname
single-level unless you're paying for Advanced Certificate Manager.

**An EPERM that wasn't a network policy.** Argo's repo-server OOMed pulling a large chart,
512Mi default limit, exit 137, CrashLoopBackOff. The app-controller then reported `dial tcp
<svc-ip>:8081: connect: operation not permitted`, which reads exactly like a Cilium
NetworkPolicy denial. It wasn't. There were simply no listeners behind the Service. I spent
an evening auditing policies that were fine. Pin the repo-server to `limits: {memory: 2Gi}`
and move on.

**`^enp.*` versus `^eno.*`.** Cilium's L2 announcement policy matches interfaces by regex and
every example on the internet uses `^enp.*`. These boxes present `eno2`. Announcements just
don't happen, LoadBalancer IPs sit there unreachable, and nothing logs that the policy
matched zero interfaces.

**`talosctl upgrade-k8s` hangs on the VIP.** The gRPC session goes stale when the API server
behind the VIP bounces, so talosctl hangs on the final kubelet-restart check even though the
upgrade already finished. Point `talosconfig` at a specific node IP for upgrades.

**OpenTofu and Terraform don't share a module registry.** I published the n8n module to the
Terraform registry, so `source = "TpyoKnig/n8n/kubernetes"` worked under Terraform and failed
with `Module not found` under OpenTofu. Same syntax, different index, and a config that's
correct but looks broken. The module is on both registries now. Publishing to one index buys you
nothing on the other, so check which one your binary is asking before you go rewriting config.

**The NAS wouldn't do NFSv4.** No export carried `fsid=0`, so there's no v4 pseudo-root and
only v3 mounts work. Longhorn's NFS backup driver mounts `-t nfs4` with no fallback and no
way to override it, so the backup target became CIFS/SMB instead. Verify with
`showmount -e` and a manual mount at each version before you design around an appliance.

## What it cost, and what it'd cost you

| Item | Paid |
| --- | --- |
| 3x ThinkCentre M920q (i5-8500T, 32 GB, 256 GB NVMe) | $672.53 |
| UniFi UNAS 4 | $451.76 |
| 2x M.2 tray + 2x Samsung PM9A1 512 GB (NAS cache) | $193.23 |
| 4x HGST 8 TB, used, off Reddit | $414.00 |
| 4x HGST 8 TB from an eBay storefront | ~~$414.55~~ refunded, all four DOA |
| **Total** | **$1,731.52** |

Plus the Pi 5 at $80 from Micro Center in early 2025.

The cluster itself was $672.53. Everything else is storage.

> [!IMPORTANT]
> Now the honest part: you can't reproduce this at these prices right now.

The AI memory crunch has been eating consumer DRAM and NAND all year. A 32 GB DDR4 kit
that was around $50 in early 2025 runs [$250 to $350
today](https://www.tomshardware.com/pc-components/ram/ram-price-index-2026-lowest-price-on-ddr5-and-ddr4-memory-of-all-capacities).
The Pi 5 is the clearest case. I paid $80 for mine, and [Raspberry Pi has raised prices
twice since](https://www.raspberrypi.com/news/more-memory-driven-price-rises/), so the same
8 GB board is $175 from CanaKit and north of $200 on Amazon as I write this. Same part, same
shelf, more than double the money in eighteen months. 1 TB NVMe contract prices [more than
doubled across the first half of
2026](https://www.tomshardware.com/pc-components/ssds/ssd-price-tracking-2026-lowest-price-on-every-m-2-ssd).

That changes the shopping advice, not the architecture. Buy used machines with the RAM
already in them, since the 96 GB in my three boxes would cost more than the boxes did if I
bought it as sticks today. That's the single biggest saving available and it's pure timing
luck on my part. Three cheap nodes still beat one good one, and not because HA is the point,
but because being able to reboot a node in the middle of the afternoon is. And used
enterprise drives from a person beat recertified drives from a storefront, at least this
once, as long as you test them the day they land.

## What I'd do differently

Not much structurally, the two constraints at the top held up better than I expected. Two
smaller things. Write the backup verification before writing the backup, see nineteen
nights. And check the NAS's NFS version before designing storage around it instead of after.

If your n8n is a container today and you want it to be a cluster, start at
[BOOTSTRAP.md](BOOTSTRAP.md), every command in order from bare metal to running
workflows, with the per-subsystem detail under [docs/](docs/). It's all sanitised,
`example.com` and `192.168.1.0/24` and no live keys, but the architecture and the gotchas
are real.
