# ── Split Ingress: ingress-nginx behind the cluster Cloudflare Tunnel ────────
#
#   webhook_host → n8n-webhook-processor   webhook / form / waiting / MCP prefixes
#   editor_host  → n8n-main                editor UI, REST API, test webhooks
#
# What the split buys is an authentication boundary. n8n's own SSO is licensed
# and this is the Community edition, so the policy has to live at the ingress.
# The editor host takes an IP allowlist; the webhook host stays open, because the
# systems calling it are machines that cannot complete an interactive login. On a
# single hostname serving both, either the editor is unauthenticated or webhooks
# break.
#
# The path prefixes come from the module output rather than being hardcoded, so
# these cannot drift as n8n adds endpoints.

locals {
  ingress_annotations = {
    "cert-manager.io/cluster-issuer" = var.cluster_issuer

    # n8n accepts large binary payloads and holds long-running requests; the
    # nginx defaults (1m body, 60s read) truncate and time them out.
    "nginx.ingress.kubernetes.io/proxy-body-size"    = "32m"
    "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
    "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
  }
}

# ── Webhook host: production webhook traffic only ────────────────────────────
# No catch-all rule, deliberately. Any other path on this hostname gets the
# controller's 404 and never reaches the editor. That is the point of the second
# hostname: it is the one facing the internet, so the only thing reachable on it
# is the surface that has to be.

resource "kubernetes_ingress_v1" "webhook" {
  metadata {
    name        = "n8n-webhook"
    namespace   = module.n8n.namespace
    annotations = local.ingress_annotations
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = var.webhook_host
      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"
            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }

        # The exception to the no-catch-all rule, and the one place this hostname
        # reaches the main pods.
        #
        # The Agents chat integrations build their URLs as
        #   getWebhookBaseUrl() + "rest/projects/<p>/agents/v2/<a>/..."
        # so the Slack OAuth callback and every platform's event webhook land on
        # this hostname under a /rest path. Only the main process registers /rest
        # routes; the webhook processors register none, so both 404 without this.
        # That is what a Slack app install actually fails on: Slack redirects the
        # browser to a URL n8n itself generated, and nothing serves it.
        #
        # Scoped to /rest/projects, a literal prefix covering all three
        # constructions with no regex and no nginx-specific annotation.
        # /rest/login and /rest/credentials stay off this hostname.
        #
        # What this does not cover is n8n adding a fourth construction outside
        # /rest/projects, which would fail the same silent way. Re-check on
        # upgrades; widening to /rest is the fix, at the cost of exposing the
        # authenticated REST API here.
        path {
          path      = "/rest/projects"
          path_type = "Prefix"
          backend {
            service {
              name = module.n8n.n8n_service_name
              port { number = module.n8n.n8n_service_port }
            }
          }
        }
      }
    }

    tls {
      hosts       = [var.webhook_host]
      secret_name = replace("${var.webhook_host}-tls", ".", "-")
    }
  }

  depends_on = [module.n8n]
}

# ── Editor host: the full surface, allowlisted ───────────────────────────────
# Serves the editor and REST API at /, and routes the webhook prefixes to the
# webhook processors ahead of that catch-all.
#
# Routing the prefixes here is not cosmetic. The module runs the chart with
# disableProductionWebhooksOnMainProcess = true, so the main pods serve none of
# them. Without these rules the catch-all hands /webhook to a main pod, the
# request falls through to the editor's SPA handler, and the caller gets HTTP 200
# with an HTML body: a delivery that reads as success while nothing ran.
#
# Test webhooks (/webhook-test) stay on the mains and are covered by the
# catch-all, which is correct — manual executions run there.

resource "kubernetes_ingress_v1" "editor" {
  metadata {
    name      = "n8n-editor"
    namespace = module.n8n.namespace

    annotations = merge(
      local.ingress_annotations,
      {
        "nginx.ingress.kubernetes.io/whitelist-source-range" = var.editor_allowlist
      },
    )
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = var.editor_host
      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_path_prefixes

          content {
            path      = path.value
            path_type = "Prefix"
            backend {
              service {
                name = module.n8n.n8n_webhook_service_name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = module.n8n.n8n_service_name
              port { number = module.n8n.n8n_service_port }
            }
          }
        }
      }
    }

    tls {
      hosts       = [var.editor_host]
      secret_name = replace("${var.editor_host}-tls", ".", "-")
    }
  }

  depends_on = [module.n8n]
}
