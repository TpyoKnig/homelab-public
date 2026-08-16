variable "kubeconfig_path" {
  description = "Path to the kubeconfig. Points at the control-plane VIP."
  type        = string
  default     = "/opt/lab/kube/config"
}

variable "namespace" {
  description = "Namespace this deployment owns."
  type        = string
  default     = "n8n"
}

variable "editor_host" {
  description = "Hostname serving the n8n editor and REST API. IP-allowlisted at the Ingress."
  type        = string
  default     = "n8n.example.com"
}

variable "webhook_host" {
  description = <<-EOT
    Hostname serving production webhooks. Open to the internet.

    Keep it single-level: Cloudflare Universal SSL covers *.example.com but not a
    second label, so hooks.n8n.example.com fails TLS at the edge without Advanced
    Certificate Manager.

    Also beware that Cloudflare silently refuses some names — the API returns
    success:true and the record never publishes. Verify with dig before assuming
    the record is live. See docs/04-cloudflare.md.
  EOT
  type        = string
  default     = "n8n-hooks.example.com"
}

variable "storage_class" {
  description = "StorageClass for the Postgres and Valkey PVCs."
  type        = string
  default     = "longhorn"
}

variable "shared_storage_class" {
  description = "RWX-capable StorageClass for the volume shared across main, worker and webhook-processor."
  type        = string
  default     = "smb-unas"
}

variable "shared_storage_size" {
  description = "Size of the shared RWX claim. Binary data from every execution lands here, so size it against retention rather than against one workflow."
  type        = string
  default     = "20Gi"
}

variable "shared_mount_path" {
  description = "Where the shared volume is mounted in the n8n container on all three pod types. Binary data goes to <this>/storage. Deliberately outside /home/node/.n8n, where the chart already mounts its own data volume on main."
  type        = string
  default     = "/opt/n8n-shared"
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer for the two Ingress certificates."
  type        = string
  default     = "letsencrypt-prod"
}

variable "editor_allowlist" {
  description = "CIDRs allowed to reach the editor hostname. Meaningful only because ingress-nginx runs with use-forwarded-headers and compute-full-forwarded-for, so it evaluates the client address from X-Forwarded-For rather than cloudflared's pod IP."
  type        = string
  default     = "203.0.113.10/32,192.168.1.0/24"
}

variable "keda_installed" {
  description = "Attests that KEDA is present. Turns on queue-depth worker scaling instead of the chart's CPU HPA."
  type        = bool
  default     = true
}

variable "timezone" {
  description = "Timezone for n8n schedules."
  type        = string
  default     = "UTC"
}

variable "n8n_version" {
  description = "n8n image tag. Bump deliberately: n8n runs its database migrations on startup and they are one-way, so rolling back to an earlier tag against a migrated database is not a supported path. Read the release notes for the whole range being crossed, not just the target. 2.32.3 is the floor for the Agents module."
  type        = string
  default     = "2.34.6"
}

variable "assistant_model" {
  description = "Model the AI Assistant uses."
  type        = string
  default     = "anthropic/claude-opus-4-8"
}

variable "sandbox_service_url" {
  description = "In-cluster n8n-sandbox-service API. Moves together with the sandbox API key in ai-assistant-secrets."
  type        = string
  default     = "http://sandbox-api.n8n-sandbox.svc.cluster.local:8080"
}

variable "searxng_url" {
  description = "In-cluster SearXNG. Only used when no Brave key is set — Brave outranks SearXNG in n8n's backend selection."
  type        = string
  default     = "http://searxng-http.searxng.svc.cluster.local:8080"
}
