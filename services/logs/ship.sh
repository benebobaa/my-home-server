#!/usr/bin/env bash
# Ship this host's journal to the lab log store (VictoriaLogs, CT 121).
# Idempotent. The observability standard's log path (ADR 0008): every
# container with `logs: true` in inventory/lab.yaml runs this, pushed by
# OpenTofu (terraform_data.log_shipping in proxmox/opentofu/logs.tf). The
# Proxmox nodes get the same setup from Ansible (`--tags logging`).
#
# Usage: ship.sh <journald insert URL>
#   e.g. ship.sh http://10.10.10.18:9428/insert/journald
#
# systemd-journal-upload keeps a cursor (--save-state): after an outage of
# the store it resumes where it stopped; the local journal is the buffer.
set -euo pipefail

url=${1:?usage: ship.sh <journald insert URL>}
export DEBIAN_FRONTEND=noninteractive

if ! dpkg -s systemd-journal-remote >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends systemd-journal-remote
fi
# The package also ships a journal *receiver* (port 19532). Nothing here
# receives logs: keep it off.
systemctl disable -q --now systemd-journal-remote.socket systemd-journal-remote.service 2>/dev/null || true
systemctl mask -q systemd-journal-remote.socket systemd-journal-remote.service

conf=/etc/systemd/journal-upload.conf.d/homelab.conf
want="# managed by services/logs/ship.sh
[Upload]
URL=${url}"
install -d -m 0755 /etc/systemd/journal-upload.conf.d
if [ "$(cat "$conf" 2>/dev/null)" != "$want" ]; then
  printf '%s\n' "$want" > "$conf"
  changed=1
fi

systemctl enable -q systemd-journal-upload.service
if [ "${changed:-0}" = 1 ] || ! systemctl is-active -q systemd-journal-upload.service; then
  systemctl restart systemd-journal-upload.service
fi
systemctl is-active -q systemd-journal-upload.service
echo "log shipping: $(hostname) → ${url}"
