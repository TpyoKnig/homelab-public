output "editor_url" {
  description = "n8n editor. IP-allowlisted at the Ingress."
  value       = "https://${var.editor_host}"
}

output "webhook_base_url" {
  description = "Base URL n8n hands out for production webhooks. Open to the internet."
  value       = "https://${var.webhook_host}"
}

output "namespace" {
  description = "Namespace this deployment owns."
  value       = module.n8n.namespace
}

output "webhook_path_prefixes" {
  description = "Prefixes routed to the webhook processors on both hostnames."
  value       = module.n8n.n8n_webhook_path_prefixes
}

output "n8n_encryption_key" {
  description = "Generated encryption key. BACK THIS UP: credentials stored in this instance cannot be decrypted without it."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "dns_records_required" {
  description = "The zone has no wildcard record; each hostname needs its own proxied CNAME at the cluster tunnel. See scripts/cf-dns-record.sh."
  value       = [var.editor_host, var.webhook_host]
}
