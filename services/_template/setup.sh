#!/usr/bin/env bash
# myapp in-guest setup. Idempotent: run by OpenTofu (terraform_data.myapp_setup)
# every time a file in this directory changes, from /root/myapp in the guest.
# Holds no secrets: deliver those like services/monitoring/secrets.sh does.
#
# The observability standard (docs/standards/observability.md) asks the app
# for: logs on stdout/stderr under systemd (no log files), no secrets in
# logs, and a cheap unauthenticated /healthz that is 2xx only when it works.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Pin versions; verify downloads by sha256 (see services/logs/setup.sh).
APP_VERSION=0.0.0

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl

# --- install the app (pinned) ------------------------------------------------
# ...

# --- service: logs go to the journal (stdout/stderr) -----------------------------
cat > /etc/systemd/system/myapp.service <<UNIT
# managed by services/myapp/setup.sh
[Unit]
Description=myapp ${APP_VERSION}
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
ExecStart=/usr/local/bin/myapp --listen=:8080
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
systemctl enable -q myapp
systemctl restart myapp

# Fail the apply if it does not come up healthy.
for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:8080/healthz >/dev/null
echo "myapp setup complete"
