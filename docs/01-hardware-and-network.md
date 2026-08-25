# 01 · Hardware & Network

This layer is everything below Kubernetes: three small PCs, their firmware, the flat
network they share, and the addresses nothing else on the LAN is allowed to take. Talos
(a minimal Linux that runs nothing but Kubernetes: no shell, no SSH, managed entirely
over an API) asks little of hardware, but what it does need (wired ethernet, predictable
IPs, the right boot order) has to be true before any cluster exists. These are also the
decisions that cost the most to change later, so they get pinned down first.

Before this: three used PCs, a Pi, and a NAS in a pile. After this: every box has a
reserved IP, a recorded NIC and disk, and firmware that survives a power cut.

## Bill of materials

| Item | Qty | Notes |
| --- | --- | --- |
| Lenovo ThinkCentre M920q Tiny | 3 | 8th/9th-gen Intel T-series, single onboard Intel I219 NIC (`e1000e`) |
| RAM | 32 GB per node | 96 GB total. Comfortable for Longhorn (replicated block storage) + Cilium (the cluster's network layer) + queue-mode n8n + Postgres |
| NVMe SSD | ~256 GB each | M.2 2280. System disk **and** Longhorn data dir live here |
| USB stick | 1 | ≥1 GB, for the Talos factory ISO, re-used across all three nodes |
| Wired ethernet | 3 ports (+1 for NAS) | Same L2 segment (same wired network, no routing in between). No Wi-Fi — the control-plane VIP (one IP that floats between the three nodes) and Cilium L2 announcements need it |
| Raspberry Pi 5 8 GB | 1 | Ops host: off-cluster observability + bastion. See [06-ops-host](06-ops-host.md) |
| NAS (4-bay, RAID 6) | 1 | Backup target and RWX shares. **Not** Longhorn's primary storage |
| 3.5" SATA drives | 4 | 8 TB 7200 RPM enterprise, bought used. Populate the NAS. Test every drive the day it arrives — a set bought recertified from a storefront arrived 4-for-4 dead and had to be returned |

Any small-form-factor x86 box works. The three things that matter: wired NIC, an NVMe
big enough for the OS plus Longhorn replicas, and a BIOS that can be told to power on
after an outage.

**Single NIC, no bonding.** Fine for a lab; accept it consciously rather than discover it.

## BIOS (each node)

- **Secure Boot: Disabled** — simplest path for Talos on metal.
- **Boot order: USB first, then NVMe** — the factory ISO boots for install, then falls through to disk.
- **After Power Loss: Last State** — nodes come back from an outage unattended.
- **Wake-on-LAN: Enabled** — remote power-on for a headless lab.
- **VT-x / VT-d: Enabled**.
- No boot-menu delay, if the firmware offers it.

## IP plan

Reserve a static block for the cluster and exclude it from the DHCP pool so nothing else
grabs those addresses.

| Role | Address | Set where |
| --- | --- | --- |
| LAN gateway / router | `192.168.1.1` | Router |
| **Control-plane VIP** | **`192.168.1.110`** | Talos `machine.network.interfaces[].vip.ip` |
| node-1 (CP + etcd + schedulable) | `192.168.1.101` | DHCP reservation |
| node-2 | `192.168.1.102` | " |
| node-3 | `192.168.1.103` | " |
| NAS | `192.168.1.239` | DHCP reservation |
| Ops host (Pi 5) | `192.168.1.100` | DHCP reservation. Deliberately outside the cluster |
| **Cilium LB pool** | `192.168.1.200–230` | `CiliumLoadBalancerIPPool`, excluded from DHCP |

All three nodes are control planes (they run Kubernetes itself, plus etcd, the cluster's
state database) and all three are schedulable, meaning ordinary workloads land on them
too. There are no dedicated worker nodes at this size.

In-use LoadBalancer IPs (addresses Cilium hands out from that pool, one per exposed
service):

| IP | Service |
| --- | --- |
| `.200` | `ingress-nginx-controller` |
| `.201` | Postgres read-write endpoint, LAN-only, for Grafana dashboards |
| `.202` | In-cluster OCI registry (Zot) |
| `.203` | PR-Agent webhook receiver |

The **VIP** gives one stable `https://192.168.1.110:6443` that floats across the three
control-plane nodes and survives any single node dying. It is what `kubeconfig` and
`talosconfig` (the client config files for `kubectl` and `talosctl`) point at.

> One exception, learned the hard way: point `talosconfig` at a **specific node IP** when
> running `talosctl upgrade-k8s`. The gRPC session to the VIP goes stale when the API
> server behind it bounces, and talosctl hangs on the final kubelet-restart check even
> though the upgrade completed.

## DNS and external access

- One Cloudflare-hosted zone. Every external hostname is a **proxied CNAME** to
  `<TUNNEL_UUID>.cfargotunnel.com`. No port forwarding, no LAN IP is public.
- Cluster ingress is `ingress-nginx` on `192.168.1.200`. LAN clients can hit it by IP;
  everything external arrives through the tunnel.
- TLS is cert-manager with a Let's Encrypt DNS-01 ClusterIssuer (domain ownership proven
  by a DNS TXT record, nothing inbound required), so the same certificate works on both
  paths. See [04-cloudflare](04-cloudflare.md).
- **Split-horizon DNS was skipped** (answering LAN queries with local IPs instead of
  sending traffic out through Cloudflare and back). One hostname per service, everything
  tunnelled. LAN names can be added later if latency ever matters.

### Router DNS interception

Some consumer routers (UniFi among them) hijack outbound UDP/53. The symptom is
cert-manager's DNS-01 propagation self-check stalling forever on `_acme-challenge` TXT
lookups while everything else looks healthy. The fix that survives router firmware
changes is to make CoreDNS forward over DNS-over-TLS — see
[03-platform-layer](03-platform-layer.md#coredns-over-dot).

## Capture NIC and disk names before writing machine configs

Talos uses predictable interface names, and the same hardware can surface as `enp0s31f6`,
`eno2` or `eth0` depending on firmware. Boot the factory ISO, let the node sit in
maintenance mode (booted from the stick into RAM, API up, nothing installed on disk) on a
DHCP lease, then:

```bash
MAINT_IP=192.168.1.<dhcp-lease>          # NOT yet one of the reservations
talosctl -n "$MAINT_IP" get links --insecure    # NIC name and driver
talosctl -n "$MAINT_IP" get disks --insecure    # /dev/nvme0n1 etc.
```

Prefer a **`deviceSelector`** matching the **driver** over a hardcoded interface name in
the machine config (the one YAML file that defines an entire Talos node). It survives
firmware quirks and is identical across all three boxes:

```yaml
network:
  interfaces:
    - deviceSelector:
        driver: e1000e
```

Record what you find:

| Node | MAC | NIC | Driver | Install disk |
| --- | --- | --- | --- | --- |
| node-1 | `aa:bb:cc:00:00:01` | `eno2` | `e1000e` | `/dev/nvme0n1` |
| node-2 | `aa:bb:cc:00:00:02` | `eno2` | `e1000e` | `/dev/nvme0n1` |
| node-3 | `aa:bb:cc:00:00:03` | `eno2` | `e1000e` | `/dev/nvme0n1` |

The Cilium L2 announcement policy (the config that makes the LB pool IPs answer on the
LAN) matches interfaces by regex, so the NIC name matters there too — `^eno.*` for these
boxes, not the more commonly copy-pasted `^enp.*`.

### Verify

Add the DHCP reservations from the recorded MACs, then boot each node back into the ISO.
Maintenance mode runs from RAM, so the one stick can leave all three sitting at their
reserved addresses at once:

```bash
for ip in 192.168.1.101 192.168.1.102 192.168.1.103; do
  talosctl -n "$ip" get links --insecure >/dev/null \
    && echo "$ip up" || echo "$ip NOT answering"
done
```

A node that does not answer is a boot-order problem or a reservation typo, in that order.

## NAS

A 4-bay appliance in RAID 6, used for two things:

1. **Off-cluster backup target** — the Pi's etcd snapshots and self-backups, plus
   Longhorn's backup store.
2. **RWX volumes** — `ReadWriteMany` claims (volumes several pods can mount and write at
   once) that Longhorn (block, RWO) cannot serve.

It is deliberately **not** Longhorn's primary storage. Longhorn replicates across the
three node NVMes; the NAS holds the cold copy so a pool-wide corruption or a two-node
loss is still recoverable.

Appliance quirks worth checking on yours before designing around it:

- **Root-squashed exports.** Plain `rsync -a` dies on `chown` with exit 23. Use
  `rsync -a --no-o --no-g`.
- **NFS version.** Some appliances publish no NFSv4 pseudo-root (no export carries
  `fsid=0`), so only v3 mounts. Longhorn's NFS backup driver mounts `-t nfs4` with no v3
  fallback and no way to override — on such an appliance, use the **CIFS/SMB** backup
  target instead. Verify with `showmount -e <nas-ip>` and a manual mount at each version
  before committing.
- **RWX reclaim.** The NFS CSI driver's controller mounts the share itself to delete a
  released PVC's directory. Where that mount fails, the PV disappears and every byte
  stays on the share — cleanup that reads as automatic and is not. Pin the NFS class to
  `reclaimPolicy: Retain` so the leak is at least visible; SMB has no portmapper
  dependency and reclaims cleanly, so it can stay on `Delete`.
