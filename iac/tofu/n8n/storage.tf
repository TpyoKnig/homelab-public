# ── Shared storage across the three pod types ────────────────────────────────
# Queue mode runs main, worker and webhook-processor pods and they do not share a
# filesystem. The chart mounts its own `data` volume on main only, and this module
# leaves persistence at the chart default, so that volume is an emptyDir.
#
# Split routing makes the gap concrete: a webhook arrives at a webhook-processor,
# the execution runs on a worker, the editor renders it on main. Three pods,
# three filesystems.
#
# Verify the RWX class before adopting it rather than assuming: a two-replica
# Deployment with pod anti-affinity, one pod writing and the other reading it
# back from a different node.
#
# On an NFS class, prefer reclaimPolicy: Retain. The NFS CSI controller mounts
# the share itself to clear a released PVC's directory, and where that mount
# fails the PV is deleted while every byte stays on the server — cleanup that
# reads as automatic and is not. Retain makes it explicit, at the cost of
# directories left behind to tidy by hand. SMB has no portmapper dependency and
# reclaims cleanly.
#
# Ordering note: apply the claim BEFORE the mount. A pod referencing a missing
# PVC stays Pending and the Helm release never goes ready.

resource "kubernetes_persistent_volume_claim_v1" "shared" {
  metadata {
    name      = "n8n-shared"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = var.shared_storage_class

    resources {
      requests = {
        storage = var.shared_storage_size
      }
    }
  }

  timeouts {
    create = "5m"
  }
}
