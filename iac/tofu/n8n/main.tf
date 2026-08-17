# n8n Community edition, queue mode, split ingress behind a Cloudflare Tunnel.
#
# This root is applied by tofu-controller, which Argo CD owns via the Terraform CR
# in iac/argocd/n8n-terraform.yaml. Bumping the module below is a one-line commit;
# the controller plans and applies it, and state lives in a cluster Secret rather
# than a file on one host. See docs/07-n8n.md.
#
# It runs identically from the CLI (`tofu init && tofu apply`) for a first
# bring-up or a debugging session.

module "n8n" {
  # Git source, not the registry address the module's README shows.
  #
  # OpenTofu resolves registry modules against registry.opentofu.org, a different
  # index from HashiCorp's registry.terraform.io. The module is published to the
  # latter only, so "TpyoKnig/n8n/kubernetes" fails here with "Module not found".
  # A git ref pins the same commit either way.
  #
  # There is no `version` argument on a git source, so the ?ref= IS the pin and a
  # range is not available here. Bumping it is a deliberate one-line commit.
  source = "git::https://github.com/TpyoKnig/terraform-kubernetes-n8n.git?ref=0.1.0"

  # ── Backing services ───────────────────────────────────────────────────────
  postgres_backend = "cnpg"
  redis_backend    = "valkey"
  create_namespace = true
  k8s_namespace    = var.namespace

  # ── The split ──────────────────────────────────────────────────────────────
  # Routing moves to ingress.tf. The module still builds everything those
  # Ingresses point at; it just stops rendering the chart's single-host pair.
  create_ingress = false

  # Without this, n8n builds webhook URLs from N8N_HOST, which is the editor
  # hostname. Every generated URL would name a host that serves the editor and
  # refuses production webhooks — and nothing errors. Only the external caller
  # ever finds out.
  n8n_webhook_url = "https://${var.webhook_host}"

  k8s_ingress_host = var.editor_host
  n8n_domain       = var.editor_host

  k8s_keda_installed = var.keda_installed
  n8n_timezone       = var.timezone

  # ── Version ────────────────────────────────────────────────────────────────
  # Pinned rather than left on the chart's floating `stable`. A node that already
  # holds the `stable` layer never re-pulls it, so the version you get depends on
  # which node the pod lands on. A pin makes it a decision instead of a side
  # effect.
  n8n_image_tag = var.n8n_version

  # ── Sizing ─────────────────────────────────────────────────────────────────
  # One replica of each pool; KEDA moves the workers when the queue actually has
  # depth. Nothing here scales on a schedule.
  cnpg_instances     = 1
  cnpg_storage_size  = "10Gi"
  cnpg_storage_class = var.storage_class

  valkey_storage_size  = "8Gi"
  valkey_storage_class = var.storage_class

  # Task runners on so Python Code nodes work — the base n8n image ships no
  # Python, so this adds a runner sidecar to the main and worker pods.
  n8n_task_runners_enabled = true

  # ── Shared storage ─────────────────────────────────────────────────────────
  # Reaches main, worker and webhook-processor alike, which is exactly what the
  # chart's own persistence does not do. See storage.tf.
  n8n_extra_volumes = [{
    name                    = "shared"
    persistent_volume_claim = { claim_name = kubernetes_persistent_volume_claim_v1.shared.metadata[0].name }
  }]

  n8n_extra_volume_mounts = [{
    name       = "shared"
    mount_path = var.shared_mount_path
    read_only  = false
  }]

  n8n_extra_env = [
    # Two hops, not the one the module's split-ingress example uses. That example
    # sits behind ingress-nginx alone; here the chain is Cloudflare edge, then
    # cloudflared, then ingress-nginx. Undercount and n8n reads a proxy address
    # as the client; overcount and it reads a value the client could have forged.
    { name = "N8N_PROXY_HOPS", value = "2" },

    # Both lines are required and the mode is the one people miss. n8n defaults
    # binary data to filesystem in regular mode but to DATABASE in scaling mode,
    # and this module always runs queue mode. Mount the volume without setting
    # the mode and every payload still goes to Postgres: the mount is there,
    # empty, and nothing reports a problem.
    #
    # Existing binary data stays where it was written — n8n records the mode per
    # reference — so old payloads remain readable. There is no migration.
    { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "filesystem" },
    { name = "N8N_STORAGE_PATH", value = "${var.shared_mount_path}/storage" },

    # ── AI Assistant + Agents ────────────────────────────────────────────────
    # Variable names verified by grepping the shipped bundle, not taken from the
    # n8n docs, which name N8N_INSTANCE_AI_SANDBOX_API_URL and
    # N8N_INSTANCE_AI_SANDBOX_API_KEY for the self-hosted sandbox. Those two
    # strings appear in no shipped build; the code reads the N8N_SANDBOX_SERVICE_
    # pair below. Nothing errors on a name n8n does not read, so the documented
    # spelling produces an assistant that loads and cannot execute anything,
    # with no log line saying why.
    #
    # The Agents module needs n8n 2.32.3 or later. Below that it half-loads with
    # nothing naming the version as the cause.
    { name = "N8N_ENABLED_MODULES", value = "instance-ai,agents" },
    { name = "N8N_INSTANCE_AI_MODEL", value = var.assistant_model },
    { name = "N8N_INSTANCE_AI_SANDBOX_ENABLED", value = "true" },
    { name = "N8N_INSTANCE_AI_SANDBOX_PROVIDER", value = "n8n-sandbox" },

    # This URL and the sandbox API key below are per-instance and have to move
    # together. Split them and the editor and assistant chat keep working while
    # only code execution fails, which reads as a sandbox outage rather than a
    # credential mismatch. See docs/08-n8n-sandbox.md.
    { name = "N8N_SANDBOX_SERVICE_URL", value = var.sandbox_service_url },

    # Web search. buildSearchMethod() picks exactly one backend, in this order:
    #   1. the n8n-hosted search proxy, if isProxyEnabled() — needs a licence AND
    #      N8N_AI_ASSISTANT_BASE_URL, so it never applies to a Community instance
    #   2. Brave, if a key is set
    #   3. SearXNG, if a URL is set
    #   4. nothing, and the tool returns an empty result list
    #
    # So setting a Brave key silently takes SearXNG out of the path.
    #
    # Do not trust the SearXNG pod log to tell you which one ran: it has no
    # access log, and a successful search is completely silent. Read the stored
    # tool output instead —
    #   select content from instance_ai_messages
    #   where content::text like '%"toolName":"research"%';
    # Brave snippets carry <strong> highlight tags; SearXNG's do not.
    { name = "N8N_INSTANCE_AI_SEARXNG_URL", value = var.searxng_url },
  ]

  # Secrets stay out of state: the module renders these as secretKeyRef and never
  # reads a value. Create the Secret out of band — putting it in this config
  # would put the keys back into state via the kubernetes_secret resource.
  #
  #   kubectl -n n8n create secret generic ai-assistant-secrets \
  #     --from-literal=model-api-key=... \
  #     --from-literal=sandbox-api-key=...
  #
  # sandbox-api-key must mirror the sandbox service's own auth secret.
  n8n_extra_env_from_secret = [
    {
      name        = "N8N_INSTANCE_AI_MODEL_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "model-api-key"
    },
    {
      name        = "N8N_SANDBOX_SERVICE_API_KEY"
      secret_name = "ai-assistant-secrets"
      secret_key  = "sandbox-api-key"
    },
  ]
}
