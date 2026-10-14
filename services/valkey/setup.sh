#!/usr/bin/env bash
# valkey in-guest setup: Debian's Valkey and redis_exporter (ADR 0016).
# Idempotent. Installs only; the per-app instances (one process, port,
# password and exporter each) are instances.sh, passwords on stdin.
#
# Run by OpenTofu (terraform_data.valkey_setup in
# ../../proxmox/opentofu/valkey.tf) every time a file in this directory
# changes, from /root/valkey in the guest.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8

apt-get update -qq
# ssl-cert: the self-signed certificate every instance presents (TLS only:
# encrypted, not verified, like Postgres's sslmode=require).
apt-get install -y -qq --no-install-recommends ca-certificates curl valkey-server valkey-tools prometheus-redis-exporter ssl-cert

# Debian starts a default instance on 6379 without a password: never used.
systemctl disable -q --now valkey-server.service prometheus-redis-exporter.service 2>/dev/null || true
systemctl mask -q valkey-server.service prometheus-redis-exporter.service

usermod -a -G ssl-cert valkey
# The exporters read each instance over its unix socket (group valkey).
usermod -a -G valkey prometheus
install -d -o valkey -g valkey -m 0750 /var/lib/valkey
install -d -o root -g prometheus -m 0750 /etc/redis-exporter

# Valkey must be built with TLS, or every instance would fail to start.
ldd /usr/bin/valkey-server | grep libssl >/dev/null || { echo "valkey-server has no TLS support" >&2; exit 1; }

# One exporter per instance: redis-exporter@<app> reads
# /etc/redis-exporter/<app>.env (address, password, listen port).
cat > /etc/systemd/system/redis-exporter@.service <<'UNIT'
# managed by services/valkey/setup.sh
[Unit]
Description=redis_exporter for valkey-server@%i
After=valkey-server@%i.service
BindsTo=valkey-server@%i.service

[Service]
User=prometheus
Group=prometheus
SupplementaryGroups=valkey
EnvironmentFile=/etc/redis-exporter/%i.env
ExecStart=/usr/bin/prometheus-redis-exporter
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
echo "valkey setup complete: $(valkey-server --version | cut -d' ' -f1-3)"
