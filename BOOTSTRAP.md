# Bootstrap — bare metal to running workloads

This is the follow-along for [STORY.md](STORY.md), written for people who self-host with
Docker and are new to Kubernetes and Talos. Before starting you need: the hardware from
[01-hardware-and-network](docs/01-hardware-and-network.md) (three used office PCs plus a
Raspberry Pi), a Cloudflare account with your domain on it, and a workstation to drive the
cluster with `talosctl` / `kubectl` / `tofu` (Stage 0 turns the Pi into exactly that, so
an SSH client and a browser are enough). Budget a weekend, not an afternoon: hands-on
time is short, but downloads, reboots, and DNS propagation fill the gaps.

Before this: four powered-off machines and a domain. After this: a three-node Kubernetes
cluster serving n8n on your own hostnames, rebuildable from git.

The single linear sequence. Every stage has a command and a ✅ verify line. Work top to
bottom; don't skip the verifies.

Hands-on time once Stage 0 is done: roughly one to two hours, most of it waiting on
`tofu apply` and Helm rollouts.

---

## Stage 0 — Ops host and prep

Do this before the cluster hardware is on the desk.

```bash
# on a fresh Debian 13 / Raspberry Pi OS Lite 64-bit
LAN_CIDR=192.168.1.0/24 ./scripts/bootstrap-ops-host.sh
```

Installs Docker, `talosctl` / `kubectl` / `helm` / `tofu`, brings up the observability
compose stack, sets up UFW and unattended-upgrades, and creates `/opt/lab/{tofu,kube,talos,talos-images,cron}`.

Then:

1. **Build the Talos factory image.** Talos ships as a built-to-order image, and the
   schematic ID names your exact build. [02-talos-cluster §1](docs/02-talos-cluster.md).
   Save the schematic ID; download the ISO to `/opt/lab/talos-images/`.
2. **Flash the USB stick.**
   ```bash
   lsblk                                   # confirm the USB device — not your backup disk
   sudo dd if=/opt/lab/talos-images/metal-amd64-v1.13.7.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```
3. **Reserve IPs** on the router: nodes `.101–.103`, VIP `.110` (a floating IP the
   control-plane nodes share), ops host `.100`, NAS `.239`, and **exclude `.200–.230`
   from the DHCP pool** for the Cilium LB range (LAN IPs the cluster hands out to
   services it exposes).
4. **Stage the OpenTofu root.** OpenTofu is the open-source Terraform fork, and this
   root describes the whole cluster. Copy `iac/tofu/cluster/` to `/opt/lab/tofu/cluster/`,
   `cp terraform.tfvars.example terraform.tfvars`, paste the install image, `tofu validate`.

✅ Grafana answers on `http://192.168.1.100:3000`; `tofu validate` is clean.

---

## Stage A — Physical and BIOS  *(~10 min per node)*

Wire all three nodes to the same switch. Label them physically **node-1 / 2 / 3** so the
IP ↔ box mapping is unambiguous.

Per node, with the USB stick in: Secure Boot **off** · boot order **USB → NVMe** · after
power loss **Last State** · Wake-on-LAN **on** · VT-x/VT-d **on**.

✅ Each node POSTs and boots from USB.

---

## Stage B — Boot Talos, capture facts  *(~10 min)*

Talos has no SSH and no shell. Everything from here on happens over its API with `talosctl`.

All three come up in maintenance mode (running from USB, unconfigured, waiting for
instructions) on DHCP leases. Note the IPs from the router.

```bash
talosctl -n <MAINT_IP> get links --insecure   # NIC name and driver
talosctl -n <MAINT_IP> get disks --insecure   # confirm /dev/nvme0n1
```

✅ All three reachable; NIC **driver** and disk path known.

---

## Stage C — Reconcile the OpenTofu root  *(~5 min)*

Only touch `terraform.tfvars` if Stage B revealed a mismatch:

- NIC driver not `e1000e` → set `nic_driver`.
- Install disk not `/dev/nvme0n1` → set `install_disk`.
- Different LAN → set `node_ips`, `vip_ip`, `gateway`.

✅ `tofu plan` shows: secrets + 3 config-applies + 1 bootstrap + 1 kubeconfig.

---

## Stage D — Provision the cluster  *(~15 min)*

```bash
cd /opt/lab/tofu/cluster
tofu init && tofu apply

tofu output -raw kubeconfig  > /opt/lab/kube/config  && chmod 600 /opt/lab/kube/config
tofu output -raw talosconfig > /opt/lab/talos/config && chmod 600 /opt/lab/talos/config
export KUBECONFIG=/opt/lab/kube/config TALOSCONFIG=/opt/lab/talos/config

talosctl -e 192.168.1.110 -n 192.168.1.101 health \
  --control-plane-nodes 192.168.1.101,192.168.1.102,192.168.1.103
```

✅ `talosctl health` reports etcd (the cluster's state store) healthy on all three.
⚠️ `kubectl get nodes` shows **NotReady** — no CNI (the pod network) yet. Expected.
🔴 **Start a timer: you have about ten minutes before Talos reboots CNI-less nodes.**

---

## Stage E — Cilium  *(immediately)*

Cilium is the CNI from Stage D's warning: the network that connects pods (a pod is one or
more containers deployed as a unit). Helm, Kubernetes' package manager, installs it from a
chart.

```bash
helm install cilium cilium/cilium -n kube-system --version 1.17.6 \
  -f iac/platform/cilium-values.yaml
cilium status --wait
kubectl apply -f iac/platform/cilium-lb-pool.yaml
```

✅ All three nodes flip to **Ready** (`kubectl get nodes`); `cilium status` all green.

---

## Stage F — Longhorn  *(~5 min)*

Longhorn turns each node's disk into replicated cluster storage, so data survives the node
it was written on. The labels let its namespace (a named slice of the cluster) run
privileged pods, which Longhorn needs for disk access.

```bash
kubectl create namespace longhorn-system
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

helm install longhorn longhorn/longhorn -n longhorn-system \
  -f iac/platform/longhorn-values.yaml
```

✅ All pods Running (`kubectl -n longhorn-system get pods`); `kubectl get sc` shows
`longhorn (default)`.

---

## Stage G — cert-manager  *(~5 min, budget 20)*

cert-manager fetches and renews Let's Encrypt certificates from inside the cluster. The
ClusterIssuers configure it to prove domain ownership by writing DNS records through your
Cloudflare token (DNS-01), so nothing needs to be reachable from the internet.

```bash
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version v1.16.5 --set crds.enabled=true \
  --set 'extraArgs={--dns01-recursive-nameservers=10.96.0.10:53,--dns01-recursive-nameservers-only}'

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token=<CF_TOKEN>
kubectl apply -f iac/platform/clusterissuers.yaml
```

If the router intercepts UDP/53, patch CoreDNS to forward over DoT **now** — see
[03-platform-layer](docs/03-platform-layer.md#coredns-over-dot). Skipping it means
cert-manager's propagation check stalls forever and you debug the wrong thing.

✅ `kubectl get clusterissuer` → both `Ready=True`. Issue a throwaway cert against
`letsencrypt-staging` first.

---

## Stage H — ingress-nginx  *(~5 min)*

ingress-nginx is the cluster's shared reverse proxy: one LoadBalancer IP from the Cilium
pool in front, per-hostname routing rules (Ingresses) behind it.

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace --version 4.11.3 \
  -f iac/platform/ingress-nginx-values.yaml
```

✅ `kubectl -n ingress-nginx get svc` shows `EXTERNAL-IP 192.168.1.200`.

---

## Stage I — Cloudflare Tunnel  *(~10 min)*

cloudflared dials out from the cluster to Cloudflare, and public traffic rides that
connection back in, so the router keeps zero open ports.

Create the tunnel and push the wildcard route ([04-cloudflare](docs/04-cloudflare.md)),
then:

```bash
kubectl create namespace cloudflared
kubectl -n cloudflared create secret generic cloudflared-tunnel-token \
  --from-literal=token=<CONNECTOR_TOKEN>
kubectl apply -f iac/platform/cloudflared.yaml
```

Deploy a throwaway `hello` Deployment (the object that runs and restarts a set of
pods) + Ingress, add its proxied CNAME, and:

✅ `curl -I https://hello.example.com` → `HTTP/2 200`, `server: cloudflare`. No inbound
firewall rule anywhere. Delete the probe afterwards.

---

## Stage J — KEDA and metrics-server  *(~5 min)*

KEDA is the autoscaler that will later grow n8n workers on queue depth. metrics-server
feeds `kubectl top` and CPU-based scaling.

```bash
helm install keda kedacore/keda -n keda --create-namespace
helm install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args={--kubelet-insecure-tls,--kubelet-preferred-address-types=InternalIP\,ExternalIP\,Hostname}'
```

✅ `kubectl top nodes` returns numbers.

---

## Stage K — Validate the platform  *(the important part, ~15 min)*

Do this **before** deploying anything you care about.

1. `kubectl get nodes` → 3× Ready, control-plane, schedulable.
2. **Node loss.** `kubectl cordon` + `drain` one node (mark it unschedulable, then
   evict its pods). The API stays up via the VIP; a
   3-replica probe app keeps serving; external requests through the tunnel keep returning
   200. Uncordon.
3. **Storage.** Create a PVC (a PersistentVolumeClaim, a pod's storage request) on
   `longhorn` → Bound, 3-replica volume created. Delete it.
4. **LoadBalancer.** `curl http://192.168.1.200` returns nginx's 404 — correct, since no
   Ingress matches the bare IP.
5. **Ingress + TLS.** A probe hostname gets a Let's Encrypt prod cert in ~90 s via DNS-01
   and returns `HTTP/2 200` through the tunnel. Delete the namespace and the CNAME.
6. **Baseline snapshot.** Nothing pending, nothing crash-looping, all tunnel connections
   healthy.

✅ Cluster is ready for workloads.

---

## Stage L — GitOps

From here the cluster's desired state lives in a git repo and Argo CD keeps the cluster
matching it: a change is a commit, and a rebuild is a clone.

1. **Forgejo on the ops host** with its own Cloudflare tunnel —
   [06-ops-host](docs/06-ops-host.md#forgejo).
2. **age keypair.** sops uses it to encrypt secrets before they touch git.
   `age-keygen -o ~/.config/sops/age/keys.txt`. Public key into
   `.sops.yaml`; private key into your password manager. Round-trip test with
   `sops -e -i` and `sops -d`.
3. **Argo CD.**
   ```bash
   helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.2.1 \
     --set 'repoServer.resources.requests.cpu=50m' \
     --set 'repoServer.resources.requests.memory=512Mi' \
     --set 'repoServer.resources.limits.memory=2Gi'
   ```
   The memory bump is not optional — see
   [05-gitops](docs/05-gitops.md#gotchas-worth-having-read-first).
4. **sops-secrets-operator** (chart 0.28.0, namespace `sops`), age key mounted from
   `Secret/sops-age`.
5. **Seed the repo**: `bootstrap/`, `infra/`, `apps/`, `secrets/`, `scripts/bootstrap.sh`.
   Apply `bootstrap/root-app.yaml`.
6. **Adopt the platform.** Extract values verbatim from live releases
   (`helm get values <release> -n <ns>`) into `infra/<name>/values.yaml`, and let Argo
   adopt them with `ServerSideApply=true`.

✅ `kubectl -n argocd get apps` → all Synced + Healthy, with the platform still serving
traffic throughout.

---

## Stage M — Workloads

### n8n

Install the two controllers that let Argo drive the OpenTofu module — Flux's
**source-controller** (fetching only, not all of Flux, no conflict with Argo) and
[**tofu-controller**](https://github.com/flux-iac/tofu-controller):

```bash
kubectl create namespace flux-system
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml \
  --dry-run=client -o yaml | \
  yq 'select(.metadata.name == "source-controller" or .kind == "CustomResourceDefinition")' | \
  kubectl apply -f -                                  # or `flux install --components=source-controller`

helm upgrade --install tofu-controller tofu-controller/tf-controller -n flux-system
```

Create the assistant secret out of band so the keys never enter Terraform state, then push
the manifests and let Argo take it:

```bash
kubectl create namespace n8n
kubectl -n n8n create secret generic ai-assistant-secrets \
  --from-literal=model-api-key=... --from-literal=sandbox-api-key=...

# copy into the GitOps repo, then adjust hosts and the editor allowlist
cp -r iac/tofu/n8n            "$GITOPS_REPO/iac/tofu/n8n"
cp    iac/argocd/n8n-terraform.yaml "$GITOPS_REPO/bootstrap/"
cd "$GITOPS_REPO"
git commit -am "n8n" && git push
kubectl apply -f iac/argocd/app-n8n.yaml
kubectl -n flux-system get terraform n8n -w
```

Create the two proxied CNAMEs (the root's `dns_records_required` output lists them), and
back up the encryption key immediately — credentials stored in the instance cannot be
decrypted without it:

```bash
kubectl -n flux-system get secret n8n-tofu-outputs \
  -o jsonpath='{.data.n8n_encryption_key}' | base64 -d
```

> For a first bring-up or a debugging session, running the root by hand
> (`cd iac/tofu/n8n && tofu init && tofu apply`) is entirely reasonable — just expect the
> controller to reconcile over anything changed out-of-band once it owns it.

Verify: `kubectl -n n8n get pods` → main, worker, and webhook pods all Running.

### n8n sandbox service

**On Talos, deploy from [`TpyoKnig/n8n-sandbox-service`](https://github.com/TpyoKnig/n8n-sandbox-service)
at tag `0.0.1`.** That tag's chart has `dataPlane.mode: dind`, which is the mode that keeps
the whole thing in-cluster on an immutable-rootfs distribution — the default `sysbox` mode
needs a node runtime you cannot install on Talos (no shell, no package manager, read-only
`/`), and its runner pod stays `Pending` forever with nothing explaining why. The third
mode, `external`, also installs here but deploys only the API and leaves you to run the
runner elsewhere. The chart is not published to any
registry, so the tag *is* the coordinate: `targetRevision: "0.0.1"`, path
`charts/n8n-sandbox-service`. Full reasoning in [08-n8n-sandbox](docs/08-n8n-sandbox.md#why-dind-mode-on-talos).

Deploy this **before** n8n points at it. Three prerequisites the chart cannot do for
itself ([08-n8n-sandbox](docs/08-n8n-sandbox.md)):

```bash
kubectl create namespace n8n-sandbox
# Without this, no runner pod is ever created and nothing obviously errors.
kubectl label namespace n8n-sandbox \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged

# runner-api-key and runner-api-keys must hold the SAME value.
RUNNER_KEY=$(openssl rand -hex 24)
kubectl -n n8n-sandbox create secret generic sandbox-auth \
  --from-literal=api-keys="$(openssl rand -hex 24)" \
  --from-literal=runner-registration-token="$(openssl rand -hex 24)" \
  --from-literal=runner-api-key="$RUNNER_KEY" \
  --from-literal=runner-api-keys="$RUNNER_KEY"

# A PRIVATE CA issuer for the four mTLS certificates — not letsencrypt-prod.
kubectl apply -f iac/apps/n8n-sandbox/ca-issuer.yaml
```

Then push `iac/apps/n8n-sandbox/values.yaml` and `iac/argocd/app-n8n-sandbox.yaml` to the
GitOps repo.

✅ `kubectl -n n8n-sandbox logs deploy/n8n-sandbox-service-api | grep 'runner registered'`,
then actually create a sandbox and run something in it — a runner that started is not a
runner that works. Commands in
[08-n8n-sandbox](docs/08-n8n-sandbox.md#verify).

### SearXNG and PR-Agent

Push their Application manifests to the GitOps repo and let Argo take them.

✅ Editor answers on its hostname; the webhook host returns a **JSON** 404 for
`/webhook/nope` (HTML means the prefixes are hitting a main pod — see
[07-n8n](docs/07-n8n.md#verifying-the-split-still-routes)).

---

## Stage N — Day-2 hygiene

```bash
sudo install -m755 scripts/etcd-snapshot.sh /opt/lab/cron/
echo '15 2 * * * root /opt/lab/cron/etcd-snapshot.sh >> /var/log/etcd-snapshot.log 2>&1' \
  | sudo tee /etc/cron.d/etcd-snapshot
```

Also wire: the Longhorn backup target and its nightly `RecurringJob`, log shipping via
Alloy, and the Prometheus scrape config against the cluster
([06-ops-host](docs/06-ops-host.md)).

Then **check the cron log after the first night.** A cron script that can't find
`talosctl` on `PATH` fails silently and indefinitely.

Verify next morning: `sudo tail /var/log/etcd-snapshot.log` shows a snapshot and no errors.

---

## If something breaks

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Nodes stuck `NotReady`, then reboot | Cilium not installed inside the ~10-minute window | Re-run `tofu apply`, then Cilium **immediately** |
| Cilium pods crash-loop | Wrong Talos values (cgroup / KubePrism / capabilities) | Recheck against [03-platform-layer](docs/03-platform-layer.md#cilium) |
| Longhorn pods `CreateContainerError` | Namespace not privileged, or extensions missing from the **install image** | Re-label the namespace; confirm the schematic is in the installer ref, not just the ISO |
| `talos_machine_bootstrap` ran too early | Provider ordering race | Keep `depends_on = [talos_machine_configuration_apply…]` |
| LoadBalancer stuck `<pending>` | Pool or L2 policy not applied, or the interface regex is wrong | Apply the pool; check the regex matches your NIC name |
| Certificate stuck on propagation check | Router hijacking UDP/53 | CoreDNS over DoT + `--dns01-recursive-nameservers=10.96.0.10:53` |
| Hostname resolves nowhere despite `success:true` | Cloudflare silently refused the record | `dig` it; pick a different name |
| Redirect loop behind the tunnel | Missing `use-forwarded-headers` / `compute-full-forwarded-for` | Set both on ingress-nginx |
| Can't reach the API after a node dies | VIP not configured | Confirm `vip.ip`; the VIP floats only across control-plane nodes |
