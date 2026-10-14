#!/usr/bin/env bash
# valkey in-guest setup: Debian's Valkey and redis_exporter (ADR 0016).
# Idempotent. Installs only; the per-app instances (one process, port,
# password and exporter each) are instances.sh, passwords on stdin.
#
# Run by OpenTofu (terraform_data.valkey_setup in
# ../../proxmox/opentofu/valkey.tf) every time a file in this directory
# changes, from /root/valkey in the guest.
#
# Argument: the monitoring host's IP (the only one that may reach the
# exporters).
set -euo pipefail

MONITORING_IP=${1:?usage: setup.sh <monitoring-ip>}

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8

apt-get update -qq
# ssl-cert: the self-signed certificate every instance presents (TLS only:
# encrypted, not verified, like Postgres's sslmode=require).
apt-get install -y -qq --no-install-recommends ca-certificates curl valkey-server valkey-tools prometheus-redis-exporter ssl-cert nftables

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
# Not BindsTo: with the instance down the exporter keeps serving redis_up 0
# (ValkeyDown), and it is not lost when the instance fails a start.
After=valkey-server@%i.service

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
# Instances bind the CT's address, which can come up after them at boot
# (found 2026-10-14: "Cannot assign requested address", and network-online
# does not wait for it in this CT). Allow the bind before the address exists
# (this CT's own network namespace only), and restart slower than Debian's
# 100 ms so a late network cannot trip the start limit.
printf '# managed by services/valkey/setup.sh\nnet.ipv4.ip_nonlocal_bind = 1\n' > /etc/sysctl.d/90-valkey-bind.conf
sysctl -q -p /etc/sysctl.d/90-valkey-bind.conf
install -d /etc/systemd/system/valkey-server@.service.d
cat > /etc/systemd/system/valkey-server@.service.d/homelab.conf <<'UNIT'
# managed by services/valkey/setup.sh
[Unit]
Wants=network-online.target
After=network-online.target systemd-sysctl.service

[Service]
RestartSec=2
UNIT

# Only the monitoring host may reach the exporters (9121 upward): they have
# no auth, and /scrape?target= makes one connect anywhere with the
# instance's password (SSRF, credential leak). Instances stay open to VLAN 20
# and the pinholes; they require their password.
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# managed by services/valkey/setup.sh
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iif lo accept
    tcp dport 9121-9199 ip saddr ${MONITORING_IP} accept
    tcp dport 9121-9199 drop
  }
}
EOF
nft -c -f /etc/nftables.conf
systemctl enable -q nftables
systemctl restart nftables

systemctl daemon-reload
echo "valkey setup complete: $(valkey-server --version | cut -d' ' -f1-3)"
