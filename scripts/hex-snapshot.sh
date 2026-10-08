#!/usr/bin/env bash
# Export the hEX config into network/routeros/snapshots/.
# Needs: sshpass, sops; ROS_USERNAME/ROS_PASSWORD come from
# network/routeros/secrets.sops.env (decrypted in memory, never on disk).
# Host: ROS_HOST (default 192.168.99.1 — the native management segment).
#   On the OOB port:  ROS_HOST=192.168.88.1 ./scripts/hex-snapshot.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets="$repo_root/network/routeros/secrets.sops.env"

# Re-run under sops once to get the credentials into the environment.
if [ -z "${ROS_PASSWORD:-}" ]; then
  exec sops exec-env "$secrets" "$(printf '%q ' "$0" "$@")"
fi

: "${ROS_USERNAME:?ROS_USERNAME missing from $secrets}"
host="${ROS_HOST:-192.168.99.1}"

stamp="$(date +%F-%H%M)"
out="$repo_root/network/routeros/snapshots/hex-${stamp}.rsc"
tmp="$(mktemp)"

# -e reads SSHPASS from the environment (-p would show it in `ps`).
SSHPASS="$ROS_PASSWORD" sshpass -e ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "${ROS_USERNAME}@${host}" '/export' > "$tmp"

mv "$tmp" "$out"
echo "saved: $out"
