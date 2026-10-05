#!/usr/bin/env bash
# Export the hEX config into network/routeros/snapshots/.
# Needs: sshpass, and ROS_USERNAME/ROS_PASSWORD in network/routeros/.env
# Host: ROS_HOST (default 192.168.99.1 — the native management segment).
#   On the OOB port:  ROS_HOST=192.168.88.1 ./scripts/hex-snapshot.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$repo_root/network/routeros/.env"
[ -f "$env_file" ] && { set -a; . "$env_file"; set +a; }

: "${ROS_USERNAME:?set ROS_USERNAME in network/routeros/.env}"
: "${ROS_PASSWORD:?set ROS_PASSWORD in network/routeros/.env}"
host="${ROS_HOST:-192.168.99.1}"

stamp="$(date +%F-%H%M)"
out="$repo_root/network/routeros/snapshots/hex-${stamp}.rsc"
tmp="$(mktemp)"

sshpass -p "$ROS_PASSWORD" ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "${ROS_USERNAME}@${host}" '/export' > "$tmp"

mv "$tmp" "$out"
echo "saved: $out"
