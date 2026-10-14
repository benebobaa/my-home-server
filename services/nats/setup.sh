#!/usr/bin/env bash
# nats in-guest setup: nats-server with JetStream (domain `hub`) and
# prometheus-nats-exporter, both pinned upstream releases (ADR 0016).
# Idempotent.
#
# Run by OpenTofu (terraform_data.nats_setup in ../../proxmox/opentofu/nats.tf)
# every time a file in this directory changes: the directory is streamed to
# /root/nats through the pinned root SSH to the node + `pct exec`, then this
# runs. Accounts and their users are accounts.sh (password hashes on stdin,
# never in this directory).
#
# Argument (from inventory/lab.yaml): this host's IP.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8

LISTEN_IP=${1:?usage: setup.sh <listen-ip>}

NATS_VERSION=2.15.0
NATS_SHA256=5d2c51caca950333aba84911df7d377f826f3a59ec36061c6539105084f65c92 # gitleaks:allow (release checksum)
EXPORTER_VERSION=0.20.2
EXPORTER_SHA256=209c87410e74eb6e9f7705735f5518a8b0459dda77acfe9db8c15021b08383af # gitleaks:allow (release checksum)

# --- packages, user ---------------------------------------------------------------
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl ssl-cert

id nats >/dev/null 2>&1 || useradd --system --home-dir /var/lib/nats --shell /usr/sbin/nologin nats
install -d -o nats -g nats -m 0750 /var/lib/nats /var/lib/nats/jetstream
install -d -o root -g nats -m 0750 /etc/nats /etc/nats/tls
# The listeners' certificate comes from OpenTofu (tls.sh, right after this);
# until then the CT's snakeoil pair, so the server can start at all.
if [ ! -s /etc/nats/tls/cert.pem ]; then
  install -o root -g nats -m 0644 /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/nats/tls/cert.pem
  install -o root -g nats -m 0640 /etc/ssl/private/ssl-cert-snakeoil.key /etc/nats/tls/key.pem
fi

fetch() { # fetch <url> <sha256> <out>
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$1"
  echo "$2  $tmp" | sha256sum -c --quiet
  mv "$tmp" "$3"
}

if [ "$(/usr/local/bin/nats-server --version 2>/dev/null)" != "nats-server: v${NATS_VERSION}" ]; then
  fetch "https://github.com/nats-io/nats-server/releases/download/v${NATS_VERSION}/nats-server-v${NATS_VERSION}-linux-amd64.tar.gz" "$NATS_SHA256" /tmp/nats.tgz
  tar -xzf /tmp/nats.tgz -C /tmp
  install -m 0755 "/tmp/nats-server-v${NATS_VERSION}-linux-amd64/nats-server" /usr/local/bin/nats-server
  rm -rf /tmp/nats.tgz "/tmp/nats-server-v${NATS_VERSION}-linux-amd64"
fi

if ! /usr/local/bin/prometheus-nats-exporter -version 2>&1 | grep -q "${EXPORTER_VERSION}"; then
  fetch "https://github.com/nats-io/prometheus-nats-exporter/releases/download/v${EXPORTER_VERSION}/prometheus-nats-exporter-v${EXPORTER_VERSION}-linux-x86_64.tar.gz" "$EXPORTER_SHA256" /tmp/pne.tgz
  install -d /tmp/pne
  tar -xzf /tmp/pne.tgz -C /tmp/pne
  install -m 0755 "$(find /tmp/pne -type f -name prometheus-nats-exporter | head -1)" /usr/local/bin/prometheus-nats-exporter
  rm -rf /tmp/pne.tgz /tmp/pne
fi

# --- config ----------------------------------------------------------------------------
# Server limits: JetStream reservations (a stream's max_bytes) count against
# these, not the disk, so they sit above the sum of the accounts' max_file
# (accounts.conf) and below the CT disk (16 GB, nats.tf).
cat > /etc/nats/nats.conf <<EOF
# managed by services/nats/setup.sh — edit the repo copy, not this file.
server_name: nats
listen: ${LISTEN_IP}:4222
http: ${LISTEN_IP}:8222
logtime: false

# Clients and leaf nodes: TLS only, the hub's self-signed certificate
# (OpenTofu, tls.sh: name and IP, pinnable by clients).
tls {
  cert_file: /etc/nats/tls/cert.pem
  key_file: /etc/nats/tls/key.pem
}

jetstream {
  # Apps that reach the hub through a leaf node without JetStream map
  # \$JS.API.> to \$JS.hub.API.> there (services/nats/README.md).
  domain: hub
  store_dir: /var/lib/nats/jetstream
  max_mem: 128MB
  max_file: 10GB
}

leafnodes {
  listen: ${LISTEN_IP}:7422
  tls {
    cert_file: /etc/nats/tls/cert.pem
    key_file: /etc/nats/tls/key.pem
  }
}

# One account per app (accounts.sh). A leaf authenticates as its app's user.
include ./accounts.conf
EOF
# Until accounts.sh has run: one account nobody can log in to, so the server
# never starts without authentication (no users at all would admit anyone).
if [ ! -s /etc/nats/accounts.conf ]; then
  locked=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  printf '# placeholder until accounts.sh runs\naccounts {\n  NOBODY { users = [ { user: nobody, password: "%s" } ] }\n}\n' "$locked" > /etc/nats/accounts.conf
fi
chown root:nats /etc/nats/nats.conf /etc/nats/accounts.conf
chmod 0640 /etc/nats/nats.conf /etc/nats/accounts.conf

# --- services: logs go to the journal -----------------------------------------------------
cat > /etc/systemd/system/nats.service <<UNIT
# managed by services/nats/setup.sh
[Unit]
Description=NATS server ${NATS_VERSION} (JetStream domain hub)
After=network-online.target
Wants=network-online.target

[Service]
User=nats
Group=nats
ExecStart=/usr/local/bin/nats-server -c /etc/nats/nats.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStopSec=60
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/nats

[Install]
WantedBy=multi-user.target
UNIT

# The exporter reads the monitoring port on this host only; 7777 is scraped
# by the monitoring host (hEX rule generated from lab.yaml).
cat > /etc/systemd/system/prometheus-nats-exporter.service <<UNIT
# managed by services/nats/setup.sh
[Unit]
Description=prometheus-nats-exporter ${EXPORTER_VERSION}
After=nats.service

[Service]
DynamicUser=yes
ExecStart=/usr/local/bin/prometheus-nats-exporter -addr ${LISTEN_IP} -port 7777 -varz -connz -healthz -jsz=all -accstatz http://${LISTEN_IP}:8222
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
systemctl enable -q nats prometheus-nats-exporter
# A restart (not a reload) only when the binary or the main config changed is
# what a provisioner re-run means; JetStream state is on disk and survives it.
systemctl restart nats
systemctl restart prometheus-nats-exporter

for _ in $(seq 1 30); do
  curl -fsS "http://${LISTEN_IP}:8222/healthz?js-enabled-only=true" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://${LISTEN_IP}:8222/healthz?js-enabled-only=true" >/dev/null
for _ in $(seq 1 15); do
  curl -fsS "http://${LISTEN_IP}:7777/metrics" 2>/dev/null | grep '^gnatsd_varz_' >/dev/null && break
  sleep 1
done
curl -fsS "http://${LISTEN_IP}:7777/metrics" | grep '^gnatsd_varz_' >/dev/null
echo "nats setup complete: nats-server ${NATS_VERSION}, exporter ${EXPORTER_VERSION}"
