variable "cluster_name" {
  type    = string
  default = "talos-lab"
}

variable "cluster_endpoint" {
  type        = string
  description = "https://<VIP>:6443 — what the generated kubeconfig points at."
  default     = "https://192.168.1.110:6443"
}

variable "vip_ip" {
  type        = string
  description = "Talos control-plane VIP. Floats across the control-plane nodes, so the API survives any single node dying."
  default     = "192.168.1.110"
}

variable "gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "node_ips" {
  type        = list(string)
  description = "Per-node static IPs. All control-plane and all schedulable in this lab. Must be outside the DHCP pool."
  default     = ["192.168.1.101", "192.168.1.102", "192.168.1.103"]
}

variable "install_image" {
  type        = string
  description = "factory.talos.dev/installer/<SCHEMATIC_ID>:<VERSION>. Must be the INSTALLER ref, not the ISO — extensions baked only into the ISO vanish on install-to-disk."
  # No default: set this in terraform.tfvars.
}

variable "install_disk" {
  type    = string
  default = "/dev/nvme0n1"
}

variable "nic_driver" {
  type        = string
  default     = "e1000e"
  description = "Matched by deviceSelector rather than interface name, which varies with firmware. Confirm on a fresh node: talosctl -n <maint-ip> get links --insecure"
}
