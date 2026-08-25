# 02 · Talos cluster (OpenTofu)

Talos is a Linux distro that runs Kubernetes and nothing else: no shell, no SSH, no package
manager. Every node is driven by its machine config (the one YAML file that fully describes
a node), so the whole cluster can be declared in code and rebuilt from it. That declaration
is this layer, ending in a kubeconfig (the credentials file kubectl uses to reach the
cluster).

Before this: three boxes in maintenance mode. After this: a working cluster.

The whole cluster is declared in OpenTofu (the open source Terraform fork) using the
[`siderolabs/talos`](https://registry.terraform.io/providers/siderolabs/talos/latest)
provider. This doc stops at "cluster is up with a kubeconfig"; everything after that is
[03-platform-layer](03-platform-layer.md).

Source: [`iac/tofu/cluster/`](../iac/tofu/cluster/).

## 1. Image Factory schematic — before booting anything

Longhorn (the replicated storage layer, installed in [03](03-platform-layer.md)) needs two
system extensions (Talos has no package manager, so extra drivers and tools are baked into
the OS itself) present in the Talos **install image**, not just the ISO. Bake them at
[factory.talos.dev](https://factory.talos.dev/) (the hosted Talos image builder):

```yaml
# schematic.yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

```bash
curl -s -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# => {"id":"<SCHEMATIC_ID>"}
```

That yields two artifacts:

- **Boot ISO** (write to USB): `https://factory.talos.dev/image/<SCHEMATIC_ID>/v1.13.7/metal-amd64.iso`
- **Install image** (goes in the machine config): `factory.talos.dev/installer/<SCHEMATIC_ID>:v1.13.7`

> **The extensions must be in the install image.** Putting them only in the ISO means
> they vanish the moment the node installs to disk and reboots, and Longhorn's pods then
> fail with `CreateContainerError` for reasons that point nowhere near the image.

## 2. Repo layout

```
iac/tofu/cluster/
├── versions.tf                 required_providers + provider block
├── variables.tf                cluster name, VIP, node IPs, install image, disk, NIC driver
├── main.tf                     secrets → machine config → apply ×3 → bootstrap → kubeconfig
├── terraform.tfvars.example    copy to terraform.tfvars; only install_image is required
└── patches/
    ├── common.yaml             install image/disk, NIC deviceSelector, Longhorn mount, registry mirrors
    └── controlplane.yaml       schedulable CPs, cni:none, proxy:disabled, VIP
```

> **State is a secret.** `talos_machine_secrets` puts the cluster PKI (the CA keys every
> node trusts) in Terraform state (the local file where tofu records what it built).
> Keep it `0600` on a backed-up host, or use an encrypted remote backend. Losing state
> does not lose the cluster, but it means re-importing to manage it again.
>
> `tofu output -raw kubeconfig` and `tofu output -raw talosconfig` are the recovery path
> whenever the client configs go missing — which happens, e.g. after an unplanned reboot
> of the ops host. The cluster is unaffected; only the client configs need re-emitting.

## 3. Machine config patches

`patches/common.yaml` — applied to every node:

```yaml
machine:
  install:
    image: ${install_image}
    disk: ${install_disk}
  network:
    interfaces:
      - deviceSelector:
          driver: ${nic_driver}
        dhcp: false
        # per-node addresses are strategic-merged in by the apply resource
        routes:
          - network: 0.0.0.0/0
            gateway: ${gateway}
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
```

Talos v1.10+ uses `/var/mnt/longhorn`, not the older `/var/lib/longhorn`. Keep this mount
and Longhorn's `defaultDataPath` in sync or Longhorn silently writes to the ephemeral
overlay.

All three nodes here are control planes (the nodes that run the Kubernetes API and etcd,
the database that holds all cluster state), so `controlplane.yaml` lands on every node too.

`patches/controlplane.yaml`:

```yaml
cluster:
  allowSchedulingOnControlPlanes: true   # 3-node HA that also runs workloads
  network:
    cni:
      name: none                          # Cilium provides CNI
  proxy:
    disabled: true                        # Cilium replaces kube-proxy
machine:
  network:
    interfaces:
      - deviceSelector:
          driver: ${nic_driver}
        vip:
          ip: ${vip_ip}
```

The `vip` is one shared virtual IP for the Kubernetes API: whichever control plane holds it
answers, and it moves if that node goes down. Everything from here on talks to the VIP, not
to any single node.

> **Schema gotcha:** on Talos v1.13 the key is `cluster.proxy.disabled`. Older docs and
> examples show `cluster.network.proxy.disabled`, which v1.13 silently ignores — you get
> kube-proxy (the stock Kubernetes service router) running alongside Cilium's replacement
> and a confusing network.

Both `cni: none` and `proxy: disabled` must be set **before** bootstrap (telling exactly one
node to start etcd and form the cluster). Changing them afterwards is a rebuild.

## 4. The resources

```hcl
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "cp" {
  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint     # https://192.168.1.110:6443 — the VIP
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches   = [
    templatefile("${path.module}/patches/common.yaml",       { ... }),
    templatefile("${path.module}/patches/controlplane.yaml", { ... }),
  ]
}

resource "talos_machine_configuration_apply" "cp" {
  for_each                    = toset(var.node_ips)
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp.machine_configuration
  node                        = each.value
  endpoint                    = each.value

  # per-node static address, merged onto the interface from common.yaml
  config_patches = [yamlencode({
    machine = { network = { interfaces = [{
      deviceSelector = { driver = var.nic_driver }
      addresses      = ["${each.value}/24"]
    }] } }
  })]
}

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.cp]   # keep this
  node                 = var.node_ips[0]                          # exactly ONE node
  endpoint             = var.node_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}
```

Two things not to change:

- **`depends_on` on the bootstrap.** The provider has a
  [known race](https://github.com/siderolabs/terraform-provider-talos/issues/265) where
  bootstrap can run ahead of the config apply.
- **Bootstrap runs on exactly one node.** etcd forms from there; the others join.

`talos_cluster_kubeconfig` is a **resource**, not a data source — it was deprecated as a
data source in provider 0.7.

## 5. Apply and verify

```bash
cd iac/tofu/cluster
cp terraform.tfvars.example terraform.tfvars   # paste your install_image
tofu init
tofu apply

tofu output -raw kubeconfig  > /opt/lab/kube/config   && chmod 600 /opt/lab/kube/config
tofu output -raw talosconfig > /opt/lab/talos/config  && chmod 600 /opt/lab/talos/config
export KUBECONFIG=/opt/lab/kube/config TALOSCONFIG=/opt/lab/talos/config

talosctl -e 192.168.1.110 -n 192.168.1.101 health \
  --control-plane-nodes 192.168.1.101,192.168.1.102,192.168.1.103
```

The health check above went through `talosctl` (the Talos CLI, node-level). `kubectl` is the
Kubernetes-level view:

```bash
kubectl get nodes
# expect all three nodes, STATUS NotReady
```

Nodes sit **`NotReady`** until a CNI (the pod network plugin) is running. That is expected —
and it is a **timer**: Talos reboots nodes that have had no CNI for about ten minutes. Go
straight to Cilium, the first install in [03-platform-layer](03-platform-layer.md).

## 6. Registry mirrors (optional, but note how they work)

If you run an in-cluster HTTP registry, image pulls are done by **containerd in the host
network namespace**, which resolves via Talos `hostDNS` on `127.0.0.53` — not CoreDNS. A
bare `myregistry.registry.svc.cluster.local:5000/...` reference can therefore never
resolve, and containerd defaults to HTTPS while the registry is HTTP-only.

Both are solved by a mirror entry in `common.yaml`. Talos matches the key **literally**
against the image reference and never resolves it:

```yaml
machine:
  registries:
    mirrors:
      "zot.registry.svc.cluster.local:5000":
        endpoints:
          - http://192.168.1.202:5000     # a node-routable LoadBalancer IP
```

Applied with `talosctl patch machineconfig` — no reboot required.

## Gotchas checklist

- [ ] Extensions in the **install image**, not just the ISO.
- [ ] `cni: none` + `proxy: disabled` set before bootstrap, with the v1.13 key spelling.
- [ ] `deviceSelector` matches the real NIC driver, confirmed in maintenance mode.
- [ ] Bootstrap targets exactly one node, with `depends_on`.
- [ ] Terraform state treated as a secret and backed up.
- [ ] Cilium installed within ten minutes of the apply.
