#!/usr/bin/env bash
# admin-gw in-guest bootstrap.
#
# Executed once by OpenTofu's remote-exec after the container is created
# (see ../../proxmox/opentofu/admin-gw.tf). Safe to re-run by hand.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

# This CT is the remote-access door: take Tailscale security fixes without
# waiting for a manual apt run. If an update ever breaks it, the fallback is the
# P7 cable (services/admin-gw/README.md).
tailscale set --auto-update

# Subnet routing needs IP forwarding inside the container (persists across
# reboots via systemd-sysctl). IPv6 is enabled too — only IPv4 routes are
# advertised, but this keeps the daemon quiet and is harmless without global
# IPv6.
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-admin-gw.conf
sysctl --system >/dev/null 2>&1 || true

if tailscale status >/dev/null 2>&1; then
  echo "tailscale: already up"
else
  cat <<'EOF'

admin-gw bootstrap complete. One interactive step remains (account-level):

  tailscale up --hostname=admin-gw --accept-dns=false \
    --advertise-routes=10.10.10.0/24,192.168.99.0/29

Then approve the two subnet routes in the Tailscale admin console and
disable key expiry for the device. Details: services/admin-gw/README.md
EOF
fi
