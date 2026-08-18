# n8n — the short path.
#
# Self-contained: `terraform init && terraform apply` in this directory gets you
# a working queue-mode n8n with CNPG Postgres, Valkey and a TLS ingress. Nothing
# else in this repo is required.
#
# ── Terraform or OpenTofu, either one ────────────────────────────────────────
# The module is published to both registry.terraform.io and registry.opentofu.org,
# so the `source` below resolves under `terraform init` and `tofu init` alike.
#
# That was not true before 2026-08-17: the two registries are separate indexes,
# the module was on Terraform's only, and `tofu init` failed here with "Module
# not found" on a config that was perfectly correct. If you hit that on some
# other module, the answer is usually which index your binary is asking, not
# your config — a git::...?ref= source is the workaround.
#
# ── This vs iac/tofu/n8n/ ────────────────────────────────────────────────────
# This file is the module doing its own routing (create_ingress defaulted on,
# one hostname). The lab root at iac/tofu/n8n/ turns that off and owns routing
# itself, because Community edition has no SSO and a single hostname forces a
# choice between an unauthenticated editor and broken webhook delivery. See
# docs/07-n8n.md. Start here; move there when you need the split.

terraform {
  required_version = ">= 1.11"

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
    kubectl    = { source = "gavinbunney/kubectl", version = ">= 1.14" }
    time       = { source = "hashicorp/time", version = "~> 0.12" }
  }
}

variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config"
}

provider "kubernetes" {
  config_path = pathexpand(var.kubeconfig_path)
}

provider "helm" {
  kubernetes = {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

# kubectl applies the CNPG Cluster CR. Unlike the kubernetes provider it does
# not read a kubeconfig implicitly, so load_config_file must be explicit.
provider "kubectl" {
  config_path      = pathexpand(var.kubeconfig_path)
  load_config_file = true
}

module "n8n" {
  # `~> 0.1` takes patches and holds the minor. Still pre-1.0, so a minor bump
  # may break the input surface; read the module CHANGELOG before widening this.
  source = "TpyoKnig/n8n/kubernetes"
  # Patch-only. `~> 0.1` would also accept 0.2.0, and pre-1.0 minors are where
  # this module is still free to break its input surface.
  version = "~> 0.1.0"

  n8n_domain = "n8n.example.com"

  k8s_ingress_class_name     = "nginx"
  k8s_ingress_cluster_issuer = "letsencrypt-prod"
}

output "n8n_url" {
  value = module.n8n.n8n_url
}

output "n8n_encryption_key" {
  description = "BACK THIS UP. Credentials stored in the instance cannot be decrypted without it."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}
