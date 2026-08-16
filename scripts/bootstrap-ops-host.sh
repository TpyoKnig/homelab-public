#!/usr/bin/env bash
# bootstrap-ops-host.sh — reproduce the Pi ops host from a fresh Debian 13
# (Raspberry Pi OS Lite 64-bit) install. Idempotent, safe to re-run.
#
# Assumptions:
#   - Running as a user with sudo (default: whoever runs the script)
#   - Pi on the LAN with internet access
#   - USB HDD (if plugged in) matches HDD_UUID below; if absent, that step no-ops
#
# Env overrides:
#   OPS_USER=<user>            default: current $USER
#   LAN_CIDR=192.168.1.0/24    adjust to your LAN
#   HDD_UUID=<uuid>            a local USB/SATA disk to mount at /mnt/usb.
#                              Empty (the default) skips that step entirely.
#   NAS_EXPORT=<ip>:<path>     NFS backup share. Empty skips the fstab entry.
#
# This is the PRE-CLUSTER state: Prometheus scrapes only itself and the host
# node-exporter. Once the cluster exists, append the kubernetes_sd block and add
# the Tempo service — see docs/06-ops-host.md.

set -euo pipefail

: "${OPS_USER:=$USER}"
: "${LAN_CIDR:=192.168.1.0/24}"
: "${HDD_UUID:=}"
: "${NAS_EXPORT:=}"
GRAFANA_PW_FILE=/opt/obs/.env

sudo -v

# --- base packages + upgrade ---
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl unzip cron ca-certificates jq openssl \
  prometheus-node-exporter \
  ufw unattended-upgrades apt-listchanges

# --- docker (via convenience script — Debian's docker.io lacks a clean compose plugin) ---
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$OPS_USER"
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
sudo systemctl enable --now docker prometheus-node-exporter
sudo systemctl restart docker

# --- arm64 tool binaries ---
if [ ! -x /usr/local/bin/talosctl ]; then
  sudo curl -fsSL "https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-arm64" \
    -o /usr/local/bin/talosctl
  sudo chmod +x /usr/local/bin/talosctl
fi
if [ ! -x /usr/local/bin/kubectl ]; then
  KVER=$(curl -sL https://dl.k8s.io/release/stable.txt)
  sudo curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/arm64/kubectl" \
    -o /usr/local/bin/kubectl
  sudo chmod +x /usr/local/bin/kubectl
fi
command -v helm >/dev/null || \
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
command -v tofu >/dev/null || {
  curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/tofu.sh
  sudo bash /tmp/tofu.sh --install-method deb
}

# --- dirs ---
sudo mkdir -p /opt/lab/{tofu,kube,talos,talos-images,cron} \
              /opt/obs \
              /mnt/data/{prom,loki,grafana} \
              /mnt/usb
sudo chown -R "$OPS_USER:$OPS_USER" /opt/lab /opt/obs
sudo chown -R 65534:65534 /mnt/data/prom
sudo chown -R 10001:10001 /mnt/data/loki
sudo chown -R 472:0       /mnt/data/grafana

# --- USB HDD mount (if present, matches HDD_UUID) ---
if [ -n "$HDD_UUID" ] && lsblk -f | grep -q "$HDD_UUID"; then
  if ! grep -q "$HDD_UUID" /etc/fstab; then
    echo "UUID=$HDD_UUID  /mnt/usb  exfat  defaults,nofail,uid=1000,gid=1000,umask=022  0  0" \
      | sudo tee -a /etc/fstab >/dev/null
  fi
  mountpoint -q /mnt/usb || sudo mount /mnt/usb
  sudo mkdir -p /mnt/usb/pi-ops
  sudo chown "$OPS_USER:$OPS_USER" /mnt/usb/pi-ops
fi

# --- NAS backup share ---
# nofail so a dead NAS never blocks boot. The backup crons check mountpoint
# before syncing, so a missing mount degrades to "local copy only" rather than
# silently writing into an empty directory.
#
# NFSv3 is explicit: some appliances publish no v4 pseudo-root and every v4
# mount fails. Check yours with `showmount -e <nas-ip>` first.
if [ -n "$NAS_EXPORT" ]; then
  sudo mkdir -p /mnt/nas/homelab_backup
  if ! grep -q '/mnt/nas/homelab_backup' /etc/fstab; then
    echo "$NAS_EXPORT  /mnt/nas/homelab_backup  nfs  _netdev,nofail,hard,noatime,nfsvers=3  0  0" \
      | sudo tee -a /etc/fstab >/dev/null
  fi
  mountpoint -q /mnt/nas/homelab_backup || sudo mount /mnt/nas/homelab_backup || \
    echo "WARN: NAS mount failed — is this host in the export list? Exports are usually IP-restricted per share." >&2
fi

# --- prometheus.yml (pre-cluster: self + host node-exporter only) ---
sudo tee /opt/obs/prometheus.yml >/dev/null <<'YAML'
global:
  scrape_interval: 30s
  external_labels: { host: pi-ops }
scrape_configs:
  - job_name: prometheus
    static_configs: [{ targets: ['localhost:9090'] }]
  - job_name: node-exporter-pi
    static_configs: [{ targets: ['host.docker.internal:9100'] }]
# When the cluster exists, append the k8s SD block from 06-Ops-Host.md.
YAML

# --- grafana admin password (generate once, keep across re-runs) ---
if [ ! -f "$GRAFANA_PW_FILE" ]; then
  GFPW=$(openssl rand -base64 18)
  sudo tee "$GRAFANA_PW_FILE" >/dev/null <<ENV
GF_SECURITY_ADMIN_PASSWORD=${GFPW}
ENV
  sudo chmod 600 "$GRAFANA_PW_FILE"
  echo "!! NEW Grafana admin pw generated at $GRAFANA_PW_FILE — sudo cat to read"
fi

# --- compose.yaml ---
sudo tee /opt/obs/compose.yaml >/dev/null <<'YAML'
services:
  prometheus:
    image: prom/prometheus:v2.55.0
    user: "65534:65534"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - /mnt/data/prom:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
      - --web.enable-lifecycle
    ports: ["127.0.0.1:9090:9090"]
    extra_hosts: ["host.docker.internal:host-gateway"]
    restart: unless-stopped

  loki:
    image: grafana/loki:3.2.0
    user: "10001:10001"
    volumes: [ "/mnt/data/loki:/loki" ]
    ports: ["3100:3100"]
    restart: unless-stopped

  grafana:
    image: grafana/grafana:11.3.0
    user: "472:0"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GF_SECURITY_ADMIN_PASSWORD}
    volumes: [ "/mnt/data/grafana:/var/lib/grafana" ]
    ports: ["3000:3000"]
    restart: unless-stopped
YAML
(cd /opt/obs && sudo docker compose up -d)

# --- UFW firewall ---
sudo ufw --force reset >/dev/null
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "$LAN_CIDR" to any port 22   proto tcp comment 'ssh (lan)'
sudo ufw allow from "$LAN_CIDR" to any port 3000 proto tcp comment 'grafana (lan)'
sudo ufw allow from "$LAN_CIDR" to any port 3100 proto tcp comment 'loki (lan)'
sudo ufw allow from "$LAN_CIDR" to any port 9100 proto tcp comment 'node-exporter (lan)'
sudo ufw allow from 172.16.0.0/12 to any port 9100 proto tcp comment 'docker bridge -> node-exporter'
sudo ufw --force enable

# --- unattended security upgrades ---
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
sudo systemctl enable --now unattended-upgrades

IP=$(hostname -I | awk '{print $1}')
echo
echo "=== BOOTSTRAP COMPLETE ==="
echo "Grafana:  http://${IP}:3000   (creds: sudo cat $GRAFANA_PW_FILE)"
echo "Loki:     :3100  |  node-exporter: :9100  |  Prom: 127.0.0.1:9090"
echo "Docker containers:"
sudo docker compose -f /opt/obs/compose.yaml ps
