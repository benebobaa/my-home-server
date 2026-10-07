#!/usr/bin/env bash
# Root-only container config for admin-gw: dev0 = /dev/net/tun passthrough.
#
# dev0 requires genuine root@pam — API tokens cannot write dev* config, so
# OpenTofu invokes this over SSH (see ../../proxmox/opentofu/admin-gw.tf).
# (IP forwarding for subnet routing is handled in-guest by provision.sh via
# /etc/sysctl.d — no host-root needed for that.)
#
# Idempotent: reboots the container only when something actually changed.
set -euo pipefail

VMID=101
CONF="/etc/pve/lxc/${VMID}.conf"

if grep -q '^dev0:' "$CONF"; then
  echo "dev0 already set on CT ${VMID}; nothing to do"
  exit 0
fi

pct set "${VMID}" -dev0 /dev/net/tun
echo "dev0 added to CT ${VMID}; rebooting to apply"
pct reboot "${VMID}"
echo "done"
