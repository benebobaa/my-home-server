#!/usr/bin/env bash
# monitoring in-guest setup: Prometheus, Alertmanager, blackbox + SNMP + PVE
# exporters, node_exporter, Grafana. Idempotent.
#
# Run by OpenTofu (terraform_data.monitoring_setup in
# ../../proxmox/opentofu/monitoring.tf) every time a file in this directory
# changes: the directory is streamed to /root/monitoring through the pinned
# root SSH to pve2 + `pct exec`, then this script runs from there.
# Holds no secrets: those come from secrets.sh and pve-token.sh.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive

PVE_EXPORTER_VERSION=3.10.1
GRAFANA_VERSION=13.2.3
GRAFANA_KEY_FPR=B53AE77BADB630A683046005963FA27710458545  # gitleaks:allow (public key fingerprint)
# Debian cannot ship a generated snmp.yml (MIB licensing): use upstream's, for
# the same release as the packaged exporter. Kept beside, not over, Debian's
# conffile /etc/prometheus/snmp.yml.
SNMP_YML_VERSION=v0.28.0
SNMP_YML_SHA256=3ce8896729f582acb822a506501b6db3e2d937d059d4fdbc55fdf293d9bdde13

# grafana.com dashboard id, pinned revision, sha256 of that download.
DASHBOARDS=(
  "1860 45 184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986 node-exporter-full"
  "10347 5 ac7b52531baf0fd6563b8419742d80b738439ad5db6819aa2cbb7b11c6858eff proxmox"
  "13659 1 9e70455850c0a8a52a4ce6313ab9113e55656b88a8419eaba84a9a91dcd48f54 blackbox"
  "14857 5 c85725d43d01a362ca3807bfde141ffe9c6bf1704b915a2451e31c0b6be4ea3d mikrotik"
)

# --- packages ---------------------------------------------------------------
install -d -m 0755 /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/grafana.gpg ]; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg
  key=$(mktemp)
  curl -fsSL -o "$key" https://apt.grafana.com/gpg.key
  gpg --show-keys --with-colons "$key" | grep -q "^fpr:::::::::${GRAFANA_KEY_FPR}:" \
    || { echo "Grafana apt key fingerprint mismatch" >&2; exit 1; }
  gpg --dearmor < "$key" > /etc/apt/keyrings/grafana.gpg
  rm -f "$key"
fi
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list

apt-get update -qq
apt-mark unhold grafana >/dev/null 2>&1 || true   # a held package refuses a new pin
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl python3-venv \
  prometheus prometheus-alertmanager prometheus-blackbox-exporter \
  prometheus-snmp-exporter prometheus-node-exporter \
  "grafana=${GRAFANA_VERSION}"
apt-mark hold grafana >/dev/null   # upgraded deliberately: bump GRAFANA_VERSION

# --- prometheus-pve-exporter (not packaged in Debian): pinned, in a venv -----
if [ "$(/opt/pve-exporter/bin/pip show prometheus-pve-exporter 2>/dev/null | awk '/^Version:/{print $2}')" != "$PVE_EXPORTER_VERSION" ]; then
  python3 -m venv /opt/pve-exporter
  /opt/pve-exporter/bin/pip install -q --disable-pip-version-check \
    "prometheus-pve-exporter==${PVE_EXPORTER_VERSION}"
fi
# Its token file (/etc/prometheus/pve.yml) is written by pve-token.sh.
cat > /etc/systemd/system/prometheus-pve-exporter.service <<'EOF'
[Unit]
Description=Prometheus exporter for the Proxmox VE API
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/prometheus/pve.yml

[Service]
User=prometheus
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file=/etc/prometheus/pve.yml --web.listen-address=127.0.0.1:9221
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

SNMP_YML=/etc/prometheus/snmp-modules.yml
if ! echo "$SNMP_YML_SHA256  $SNMP_YML" | sha256sum -c --quiet 2>/dev/null; then
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "https://raw.githubusercontent.com/prometheus/snmp_exporter/${SNMP_YML_VERSION}/snmp.yml"
  echo "$SNMP_YML_SHA256  $tmp" | sha256sum -c --quiet
  install -m 0644 "$tmp" "$SNMP_YML"
  rm -f "$tmp"
fi

# --- service arguments --------------------------------------------------------
# Prometheus: 30 days, capped at 8 GB (12 GB disk). Lifecycle API off; reload
# with SIGHUP (systemctl reload).
cat > /etc/default/prometheus <<'EOF'
# managed by services/monitoring/setup.sh
ARGS="--storage.tsdb.retention.time=30d --storage.tsdb.retention.size=8GB --web.listen-address=:9090"
EOF
# Alertmanager: single instance, no gossip port, localhost only — it has no
# login, and whoever reaches it can silence alerts. Silences go through
# Grafana (authenticated; Alertmanager datasource) or amtool in the CT.
cat > /etc/default/prometheus-alertmanager <<'EOF'
# managed by services/monitoring/setup.sh
ARGS="--cluster.listen-address= --web.listen-address=127.0.0.1:9093"
EOF
# Exporters: localhost only (Prometheus is the only client).
cat > /etc/default/prometheus-blackbox-exporter <<'EOF'
# managed by services/monitoring/setup.sh
ARGS="--config.file=/etc/prometheus/blackbox.yml --web.listen-address=127.0.0.1:9115"
EOF
# SNMP: upstream's generated modules + the v3 credentials (secrets.sh).
# ICMP probes: unprivileged ping sockets for the `prometheus` group (the
# exporter tries these first). CAP_NET_RAW does not work here: the package
# sets a file capability on the binary, which clears ambient capabilities and
# grants nothing inside an unprivileged CT.
rm -rf /etc/systemd/system/prometheus-blackbox-exporter.service.d
gid=$(getent group prometheus | cut -d: -f3)
echo "net.ipv4.ping_group_range = $gid $gid" > /etc/sysctl.d/60-blackbox-ping.conf
sysctl -q -p /etc/sysctl.d/60-blackbox-ping.conf
cat > /etc/default/prometheus-snmp-exporter <<'EOF'
# managed by services/monitoring/setup.sh
ARGS="--config.file=/etc/prometheus/snmp-modules.yml --config.file=/etc/prometheus/snmp-auth.yml --web.listen-address=127.0.0.1:9116"
EOF
cat > /etc/default/prometheus-node-exporter <<'EOF'
# managed by services/monitoring/setup.sh
ARGS="--web.listen-address=127.0.0.1:9100"
EOF
# Placeholder until secrets.sh writes the real credentials; the exporter
# refuses to start without the file.
[ -f /etc/prometheus/snmp-auth.yml ] || install -m 0640 -o root -g prometheus /dev/stdin /etc/prometheus/snmp-auth.yml <<'EOF'
auths: {}
EOF

# --- configs from the repo ------------------------------------------------------
install -m 0644 "$SRC/blackbox.yml" /etc/prometheus/blackbox.yml
install -d -m 0755 /etc/prometheus/rules
rm -f /etc/prometheus/rules/*.yml
install -m 0644 "$SRC"/prometheus/rules/*.yml /etc/prometheus/rules/
install -m 0644 "$SRC/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml
promtool check config --syntax-only /etc/prometheus/prometheus.yml >/dev/null
promtool check rules /etc/prometheus/rules/*.yml >/dev/null
# alertmanager.yml is rendered by secrets.sh (it needs the chat id).

# --- Grafana ---------------------------------------------------------------------
install -d -m 0755 /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/homelab.conf <<'EOF'
# managed by services/monitoring/setup.sh
[Service]
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
Environment=GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
Environment=GF_NEWS_NEWS_FEED_ENABLED=false
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_AUTH_ANONYMOUS_ENABLED=false
EOF
install -m 0644 "$SRC/grafana/datasource.yml" /etc/grafana/provisioning/datasources/homelab.yml
install -m 0644 "$SRC/grafana/dashboards.yml" /etc/grafana/provisioning/dashboards/homelab.yml
install -d -m 0755 /var/lib/grafana/dashboards
for d in "${DASHBOARDS[@]}"; do
  read -r id rev sha name <<<"$d"
  out=/var/lib/grafana/dashboards/$name.json
  if [ ! -f "$out.sha256" ] || [ "$(cat "$out.sha256")" != "$sha" ]; then
    tmp=$(mktemp)
    curl -fsSL -o "$tmp" "https://grafana.com/api/dashboards/$id/revisions/$rev/download"
    echo "$sha  $tmp" | sha256sum -c --quiet
    # Import-style dashboards reference ${DS_PROMETHEUS}; file provisioning
    # does not substitute inputs, so point them at the provisioned uid.
    # shellcheck disable=SC2016  # a literal ${DS_PROMETHEUS}, not an expansion
    sed 's/\${DS_PROMETHEUS}/prometheus/g' "$tmp" > "$out"
    echo "$sha" > "$out.sha256"
    rm -f "$tmp"
  fi
done

# --- start -----------------------------------------------------------------------
systemctl daemon-reload
for s in prometheus-node-exporter prometheus-blackbox-exporter prometheus-snmp-exporter grafana-server; do
  systemctl enable -q "$s"
  systemctl restart "$s"
done
systemctl enable -q prometheus-pve-exporter prometheus prometheus-alertmanager
[ -f /etc/prometheus/pve.yml ] && systemctl restart prometheus-pve-exporter
systemctl restart prometheus
# Alertmanager only runs with a rendered config (secrets.sh); Debian's sample
# config would otherwise send nowhere useful.
if grep -q 'managed by services/monitoring/secrets.sh' /etc/prometheus/alertmanager.yml 2>/dev/null; then
  systemctl restart prometheus-alertmanager
fi

echo "monitoring setup complete: Prometheus :9090, Alertmanager :9093, Grafana :3000"
