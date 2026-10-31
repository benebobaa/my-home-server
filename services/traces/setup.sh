#!/usr/bin/env bash
# traces in-guest setup: VictoriaTraces, the lab's trace store (ADR 0028).
# Idempotent.
#
# Run by OpenTofu (terraform_data.traces_setup in
# ../../proxmox/opentofu/traces.tf) every time a file in this directory
# changes: the directory is streamed to /root/traces through the pinned root
# SSH to the node + `pct exec`, then this script runs from there.
#
# Receives:
#   OTLP/HTTP  :10428 /insert/opentelemetry/v1/traces   senders in MGMT (ADR 0028)
# Serves:
#   :10428 /select/tempo    Grafana's Tempo data source (platform-traces, Traces Drilldown)
#   :10428 /select/jaeger   the Jaeger query API (the smoke test)
#   :10428 /select/vmui     the built-in UI
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Community release. Both digests come from the release's _checksums.txt:
# the tarball, and the binary inside it.
TRACES_VERSION=v0.12.1
TRACES_TARBALL_SHA256=966c01559cc3f3452bae136106ec24c484f2383c4c4f9b51ebf2f6c4163721ba
TRACES_BIN_SHA256=37483a51eab7d7e287478340c6ac976e46e5ccd94cfb29601a7b3003eef852c4

# 30 days, the same as the log store, hard-capped at 16 GiB (20 GB disk, traces.tf):
# a span flood drops the oldest days instead of filling the disk.
RETENTION=30d
DISK_CAP=16GiB

# --- binary ---------------------------------------------------------------------
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl

if ! echo "$TRACES_BIN_SHA256  /usr/local/bin/victoria-traces" | sha256sum -c --quiet >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/vt.tar.gz" \
    "https://github.com/VictoriaMetrics/VictoriaTraces/releases/download/${TRACES_VERSION}/victoria-traces-linux-amd64-${TRACES_VERSION}.tar.gz"
  echo "$TRACES_TARBALL_SHA256  $tmp/vt.tar.gz" | sha256sum -c --quiet
  tar -xzf "$tmp/vt.tar.gz" -C "$tmp" victoria-traces-prod
  echo "$TRACES_BIN_SHA256  $tmp/victoria-traces-prod" | sha256sum -c --quiet
  install -m 0755 "$tmp/victoria-traces-prod" /usr/local/bin/victoria-traces
  rm -rf "$tmp"
fi

id victoriatraces >/dev/null 2>&1 \
  || useradd --system --home-dir /var/lib/victoria-traces --shell /usr/sbin/nologin victoriatraces
install -d -m 0750 -o victoriatraces -g victoriatraces /var/lib/victoria-traces

# --- service ----------------------------------------------------------------------
cat > /etc/systemd/system/victoria-traces.service <<EOF
# managed by services/traces/setup.sh
[Unit]
Description=VictoriaTraces — lab trace store
After=network-online.target
Wants=network-online.target

[Service]
User=victoriatraces
ExecStart=/usr/local/bin/victoria-traces \\
  -storageDataPath=/var/lib/victoria-traces \\
  -retentionPeriod=${RETENTION} \\
  -retention.maxDiskSpaceUsageBytes=${DISK_CAP} \\
  -httpListenAddr=:10428
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/victoria-traces

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q victoria-traces
systemctl restart victoria-traces

for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:10428/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:10428/health >/dev/null
echo "traces setup complete: VictoriaTraces ${TRACES_VERSION} on :10428 (OTLP/HTTP ingest, Tempo and Jaeger query, /select/vmui)"
