#!/usr/bin/env bash
# logs in-guest setup: VictoriaLogs, the lab's log store (ADR 0008).
# Idempotent.
#
# Run by OpenTofu (terraform_data.logs_setup in
# ../../proxmox/opentofu/logs.tf) every time a file in this directory
# changes: the directory is streamed to /root/logs through the pinned root
# SSH to the node + `pct exec`, then this script runs from there.
#
# Receives:
#   journald  HTTP :9428 /insert/journald   every node and guest (ship.sh)
#   syslog    UDP  :5514                    the hEX (network/routeros/logging.tf)
# Serves queries on :9428 (Grafana datasource; the built-in UI at /select/vmui).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Community release, sha256 of the tarball from the release's _checksums.txt.
VL_VERSION=v1.53.0
VL_SHA256=55feba89713cafa952673f91b8b38e7701bb0290989263da671b47a0de16edd3

# 30 days, hard-capped at 6 GiB (10 GB disk): a log flood drops the oldest
# days instead of filling the disk. LogsNearDiskCap fires before the cap.
RETENTION=30d
DISK_CAP=6GiB

# --- binary ---------------------------------------------------------------------
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl

if [ "$(/usr/local/bin/victoria-logs -version 2>/dev/null | grep -o 'v[0-9.]*' | head -1)" != "$VL_VERSION" ]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/vl.tar.gz" \
    "https://github.com/VictoriaMetrics/VictoriaLogs/releases/download/${VL_VERSION}/victoria-logs-linux-amd64-${VL_VERSION}.tar.gz"
  echo "$VL_SHA256  $tmp/vl.tar.gz" | sha256sum -c --quiet
  tar -xzf "$tmp/vl.tar.gz" -C "$tmp" victoria-logs-prod
  install -m 0755 "$tmp/victoria-logs-prod" /usr/local/bin/victoria-logs
  rm -rf "$tmp"
fi

id victorialogs >/dev/null 2>&1 \
  || useradd --system --home-dir /var/lib/victoria-logs --shell /usr/sbin/nologin victorialogs
install -d -m 0750 -o victorialogs -g victorialogs /var/lib/victoria-logs

# --- service ----------------------------------------------------------------------
# Stream fields: journald keeps its defaults (_MACHINE_ID, _HOSTNAME,
# _SYSTEMD_UNIT). Syslog drops proc_id from the default: it changes on every
# process restart, which would make a new stream each time.
cat > /etc/systemd/system/victoria-logs.service <<EOF
# managed by services/logs/setup.sh
[Unit]
Description=VictoriaLogs — lab log store
After=network-online.target
Wants=network-online.target

[Service]
User=victorialogs
ExecStart=/usr/local/bin/victoria-logs \\
  -storageDataPath=/var/lib/victoria-logs \\
  -retentionPeriod=${RETENTION} \\
  -retention.maxDiskSpaceUsageBytes=${DISK_CAP} \\
  -httpListenAddr=:9428 \\
  -syslog.listenAddr.udp=:5514 \\
  -syslog.timezone=Asia/Jakarta \\
  -syslog.streamFields.udp='["hostname","app_name"]'
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/victoria-logs

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q victoria-logs
systemctl restart victoria-logs

for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:9428/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:9428/health >/dev/null
echo "logs setup complete: VictoriaLogs ${VL_VERSION} on :9428 (journald, queries), :5514/udp (syslog)"
