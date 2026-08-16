resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "cp" {
  cluster_name     = var.cluster_name
  cluster_endpoint = var.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    templatefile("${path.module}/patches/common.yaml", {
      install_image = var.install_image
      install_disk  = var.install_disk
      nic_driver    = var.nic_driver
      gateway       = var.gateway
    }),
    templatefile("${path.module}/patches/controlplane.yaml", {
      vip_ip     = var.vip_ip
      nic_driver = var.nic_driver
    }),
  ]
}

resource "talos_machine_configuration_apply" "cp" {
  for_each                    = toset(var.node_ips)
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp.machine_configuration
  node                        = each.value
  endpoint                    = each.value

  # Per-node static address, strategic-merged onto the interface from common.yaml.
  # The deviceSelector has to be repeated here or the merge has nothing to match on.
  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [{
            deviceSelector = { driver = var.nic_driver }
            addresses      = ["${each.value}/24"]
          }]
        }
      }
    })
  ]
}

resource "talos_machine_bootstrap" "this" {
  # Provider issue #265: bootstrap can race ahead of the config apply without this.
  # https://github.com/siderolabs/terraform-provider-talos/issues/265
  depends_on = [talos_machine_configuration_apply.cp]

  # Exactly one node. etcd forms here and the others join.
  node                 = var.node_ips[0]
  endpoint             = var.node_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}

# A resource, not a data source — deprecated as a data source in provider 0.7.
resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]
  node                 = var.node_ips[0]
  client_configuration = talos_machine_secrets.this.client_configuration
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.vip_ip]
  nodes                = var.node_ips
}

# These two outputs are the recovery path whenever the client configs go missing —
# an ops-host rebuild, an unplanned reboot that lost an ephemeral ~/.kube/config.
# The cluster is unaffected; only the client configs need re-emitting.
output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}
