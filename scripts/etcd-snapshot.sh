#!/bin/bash
# etcd-snapshot.sh — nightly etcd snapshot from the ops host, mirrored to the NAS.
#
# Install to /opt/lab/cron/etcd-snapshot.sh, run from /etc/cron.d/etcd-snapshot:
#   15 2 * * * root /opt/lab/cron/etcd-snapshot.sh >> /var/log/etcd-snapshot.log 2>&1
#
# Single-node target: etcd replicates, so any healthy control-plane node yields
# the same snapshot.
set -euo pipefail

NODE=${NODE:-192.168.1.101}
TALOSCONFIG_PATH=${TALOSCONFIG_PATH:-/opt/lab/talos/config}
LOCAL_DIR=${LOCAL_DIR:-/var/backups/etcd}
NAS_DIR=${NAS_DIR:-/mnt/nas/homelab_backup}
RETAIN_DAYS=${RETAIN_DAYS:-14}

OUT="$LOCAL_DIR/etcd-$(date +%Y%m%d-%H%M).snap"
mkdir -p "$(dirname "$OUT")"

# ABSOLUTE PATH, deliberately. Cron's PATH lacks /usr/local/bin, and a bare
# `talosctl` here fails silently every night — this ate nineteen nights of
# snapshots before anyone read the log.
/usr/local/bin/talosctl --talosconfig "$TALOSCONFIG_PATH" -n "$NODE" etcd snapshot "$OUT"

find "$LOCAL_DIR" -name 'etcd-*.snap' -mtime "+$RETAIN_DAYS" -delete

# Copy 1 = NAS, copy 2 = this host.
#   --no-o --no-g : the NAS export is root-squashed, plain `rsync -a` dies on
#                   chown with exit 23.
#   --delete      : this is what propagates the retention window to the NAS.
#                   Drop it and the NAS grows forever. Corollary: never point
#                   another system's backup target inside a tree this owns.
if mountpoint -q "$NAS_DIR"; then
  mkdir -p "$NAS_DIR/pi-ops/etcd"
  rsync -a --no-o --no-g --delete "$LOCAL_DIR/" "$NAS_DIR/pi-ops/etcd/"
else
  echo "$(date -Iseconds) WARN $NAS_DIR not mounted — NAS copy skipped" >&2
fi
