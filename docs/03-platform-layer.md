# 03 · Platform layer

Turns a bare Talos cluster into something workloads can land on. Install in this order;
each layer assumes the previous one is healthy. Values files live in
[`iac/platform/`](../iac/platform/).

Coming from Docker, this layer covers what the daemon and a reverse proxy container gave
you between them: pod networking, persistent volumes, TLS, a front door, autoscaling
signals. Kubernetes ships with none of it and makes you pick each piece. Nearly
everything installs with Helm (the Kubernetes package manager: a chart is the package, a
values file is its config).

Before this: three NotReady nodes running nothing. After this: storage, ingress and TLS on tap.

## Cilium

CNI (the plugin that wires pod networking), kube-proxy replacement (Cilium takes over the
Service routing kube-proxy normally does), LoadBalancer IPs and Hubble (Cilium's traffic
observability UI). The machine config already set `cni: none` and `proxy: disabled`.

The Talos-specific values matter — the chart defaults do not work here:

```yaml
ipam:
  mode: kubernetes
kubeProxyReplacement: true
k8sServiceHost: localhost      # Talos KubePrism...
k8sServicePort: 7445           # ...so Cilium reaches the API without kube-proxy
cgroup:
  autoMount:
    enabled: false             # Talos already mounts cgroup v2
  hostRoot: /sys/fs/cgroup
securityContext:
  capabilities:
    ciliumAgent: [CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID]
    cleanCiliumState: [NET_ADMIN,SYS_ADMIN,SYS_RESOURCE]
l2announcements:
  enabled: true                # advertise LoadBalancer IPs on the LAN over ARP
hubble:
  relay: { enabled: true }
  ui:    { enabled: true }
```

```bash
helm install cilium cilium/cilium -n kube-system --version 1.17.6 -f iac/platform/cilium-values.yaml
cilium status --wait
kubectl get nodes            # all three flip to Ready
```

LoadBalancer IPs, replacing MetalLB (the add-on most bare-metal clusters run for this):

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata: { name: lan-pool }
spec:
  blocks: [{ start: "192.168.1.200", stop: "192.168.1.230" }]
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: { name: lan-l2 }
spec:
  interfaces: ["^eno.*"]       # match YOUR NIC name, not the copy-pasted ^enp.*
  externalIPs: true
  loadBalancerIPs: true
```

If a Service stays `<pending>` (the EXTERNAL-IP column of `kubectl get svc`), it is almost
always the pool not applied, the pool overlapping the DHCP range, or that interface regex.

## Longhorn

Replicated block storage. Needs the `iscsi-tools` and `util-linux-tools` extensions
(already in the image) and a **privileged** namespace (labels that lift the pod security
defaults blocking host access) — without the labels, Longhorn's system pods never start:

```bash
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged
```

```yaml
defaultSettings:
  defaultDataPath: /var/mnt/longhorn      # must match the kubelet extraMount
  defaultReplicaCount: 3                  # one per node — survives a node loss
persistence:
  defaultClass: true
  defaultClassReplicaCount: 3
```

With three nodes and replica count 3, every volume tolerates one node down. On a ~256 GB
disk shared with the OS, thin-provision and do not over-request.

### Backup target

Point Longhorn at the NAS. On appliances that publish no NFSv4 namespace, use CIFS:

```yaml
defaultBackupStore:
  backupTarget: cifs://192.168.1.239/homelab_backup/longhorn
  backupTargetCredentialSecret: longhorn-cifs
```

Three things that cost real time:

- **`defaultSettings.backupTarget` is a silent no-op** in Longhorn 1.9+. The setting was
  removed in favour of the `BackupTarget` CR (a custom resource, Longhorn's own object
  type in the Kubernetes API); `defaultBackupStore` is the key that populates it.
- **Clearing a target needs a manual patch** — removing the Helm value leaves the CR
  populated:
  `kubectl -n longhorn-system patch backuptarget default --type merge -p '{"spec":{"backupTargetURL":""}}'`
- **Give the backup its own prefix.** If the same share also receives an `rsync --delete`
  mirror from another host, a target pointed inside that tree gets wiped nightly.

Talos needs no extension for CIFS: `cifs` and `smb3` are compiled into its kernel.

Nightly job for every volume:

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata: { name: nightly-backup, namespace: longhorn-system }
spec:
  cron: "0 2 * * *"
  task: backup
  retain: 14
  concurrency: 2
  groups: [default]
```

Backups are block-level incremental, so fourteen nightlies are far less than fourteen
times the volume size. Verify a restore quarterly — an unrestored backup is a rumour.

## RWX volumes

Longhorn is RWO (one node mounts a volume read-write at a time). For `ReadWriteMany`
(RWX, a volume several pods can mount read-write at once) — which queue-mode n8n needs,
since main, worker and webhook pods do not otherwise share a filesystem — add the CSI
drivers (storage plugins, each installing a StorageClass that volume claims request by
name) for the NAS:

- `csi-driver-smb` → StorageClass `smb-unas`, `reclaimPolicy: Delete`. **Prefer this.**
- `csi-driver-nfs` → StorageClass `nfs-unas`, `reclaimPolicy: Retain` (see the reclaim
  caveat in [01-hardware-and-network](01-hardware-and-network.md#nas)).

```yaml
# smb-unas
parameters:
  source: //192.168.1.239/k8s_storage
mountOptions: [dir_mode=0770, file_mode=0770, uid=1000, gid=1000, noperm]
```

SMB carries no uid/gid of its own — the server decides identity at login and the mount
options decide ownership. `uid=1000` is what makes files land as n8n's `node` user.

Verify a class before building on it: two pods with anti-affinity on different nodes,
one writes, the other reads it back.

## CoreDNS over DoT

Needed if the router hijacks outbound UDP/53. DoT (DNS over TLS) moves the upstream
lookups to an encrypted session the router cannot rewrite. Patch the `kube-system/coredns`
Corefile (the config for CoreDNS, the cluster's own DNS server):

```
forward . tls://1.1.1.1 tls://1.0.0.1 tls://8.8.8.8 {
    tls_servername cloudflare-dns.com
    health_check 5s
    max_concurrent 1000
}
```

```bash
kubectl -n kube-system rollout restart deploy/coredns
```

This also fixes public DNS for every other workload in the cluster, and it has no
downside even once the router is fixed — worth keeping as the known-good path.

## cert-manager

The in-cluster ACME client: it issues and renews Let's Encrypt certificates as Kubernetes
objects, the job Caddy or Traefik handled by itself on the Docker box.

```bash
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version v1.16.5 --set crds.enabled=true \
  --set 'extraArgs={--dns01-recursive-nameservers=10.96.0.10:53,--dns01-recursive-nameservers-only}'

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token=<TOKEN>
```

`--dns01-recursive-nameservers-only` pointed at in-cluster CoreDNS (`10.96.0.10:53`,
which forwards over DoT) is what makes the propagation self-check pass behind a
DNS-intercepting router. A cert that stalls for five minutes on propagation-check and
then issues in ninety seconds once this is set is the tell.

ClusterIssuer (the cluster-wide recipe cert-manager uses to get certificates), DNS-01
(the ACME challenge answered with a DNS TXT record) against Cloudflare — works for
internal and external names alike, since nothing has to be reachable:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: letsencrypt-prod }
spec:
  acme:
    email: you@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef: { name: letsencrypt-prod-account-key }
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef: { name: cloudflare-api-token, key: api-token }
        selector: { dnsZones: [example.com] }
```

Duplicate it with `letsencrypt-staging` and the ACME staging URL while testing — the
production rate limits are low and unforgiving.

**Cloudflare API token scopes:** `Zone:DNS:Edit` + `Zone:Zone:Read` on the zone. For the
tunnel, additionally `Account:Cloudflare Tunnel:Edit`.

## ingress-nginx

The cluster's reverse proxy. Ingress resources (per-hostname routing rules stored in the
cluster) tell it where to route, so there is no nginx.conf to hand-edit.

Install as `Service type=LoadBalancer`; Cilium hands it `192.168.1.200`.

```yaml
controller:
  service: { type: LoadBalancer }
  ingressClassResource: { default: true }
  watchIngressWithoutClass: true
  config:
    use-forwarded-headers: "true"        # trust cloudflared's X-Forwarded-Proto
    compute-full-forwarded-for: "true"
```

**Both flags are required behind Cloudflare.** Without them, a request arriving through
the tunnel reaches nginx as HTTP, gets a 308 to HTTPS, comes back through Cloudflare as
HTTPS again, and loops forever.

They are also what makes IP allowlists work at all: with them, nginx evaluates the real
client address from `X-Forwarded-For` instead of cloudflared's pod IP. Without them every
request appears to come from the tunnel and an allowlist admits everyone or nobody.

## KEDA

```bash
helm install keda kedacore/keda -n keda --create-namespace
```

Nothing Talos-specific. Needed for queue-depth worker autoscaling in n8n. KEDA scales
pods on external metrics like Redis queue length, numbers the stock HPA (Horizontal Pod
Autoscaler, which only watches CPU and memory) cannot see.

## metrics-server

Talos kubelets (the per-node agent that runs pods) present self-signed certificates, so:

```bash
helm install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname}'
```

Without it every CPU-based HPA reads `<unknown>/70%` forever.

## Verify

One pass over the whole layer before building on it:

```bash
kubectl get pods -A | grep -vE 'Running|Completed'   # header only, anything else is a problem
kubectl get storageclass                             # longhorn (default), smb-unas, nfs-unas
kubectl get clusterissuer                            # letsencrypt-prod shows READY True
kubectl top nodes                                    # real numbers, not a Metrics API error
```

## Resource budget

Rough steady-state overhead before workloads, on 32 GB/node:

- Cilium + Hubble: ~0.5–1 GB per node
- Longhorn: ~1–1.5 GB per node (instance manager + replicas)
- ingress-nginx / cert-manager / KEDA: under 0.5 GB total

The rest is yours. On 96 GB total there is no need to trim the platform to fit a
queue-mode n8n plus Postgres, Redis and object storage.
