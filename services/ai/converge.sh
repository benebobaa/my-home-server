#!/usr/bin/env bash
# ai — converge the inside of the AI workstation VM from its node (pve1),
# through the guest agent. Run by proxmox/opentofu/ai.tf, which ships this
# directory to /root/ai on pve1 first.
#
# Usage: converge.sh <vmid> <login user>
#
# Steps: wait for the agent (cloud-init installs it on first boot) → in-guest
# setup (provision.sh) → one reboot if the NVIDIA driver was just installed
# → prove the GPU with nvidia-smi.
set -euo pipefail

VMID=${1:?usage: converge.sh <vmid> <user>}
USER_NAME=${2:?}
DIR=$(cd "$(dirname "$0")" && pwd)

wait_agent() {
  for _ in $(seq 1 120); do
    qm agent "$VMID" ping >/dev/null 2>&1 && return 0
    sleep 5
  done
  echo "ai: guest agent of VM ${VMID} not answering after 10 min" >&2
  return 1
}

# gexec <timeout s> <stdin file or -> <command...>: run in the guest, print
# its output, return its exit code (a timeout counts as failure).
gexec() {
  local timeout=$1 input=$2 out
  shift 2
  if [ "$input" = - ]; then
    out=$(qm guest exec "$VMID" --timeout "$timeout" -- "$@")
  else
    out=$(qm guest exec "$VMID" --pass-stdin 1 --timeout "$timeout" -- "$@" < "$input")
  fi
  OUT="$out" python3 -c '
import json, os, sys
d = json.loads(os.environ["OUT"])
sys.stdout.write(d.get("out-data", ""))
sys.stderr.write(d.get("err-data", ""))
sys.exit(d.get("exitcode", 1) if d.get("exited") else 124)'
}

wait_agent
gexec 3600 "$DIR/provision.sh" bash -s -- "$USER_NAME"

if gexec 30 - test -f /run/ai-reboot-required; then
  echo "ai: rebooting VM ${VMID} to load the NVIDIA driver"
  qm reboot "$VMID" --timeout 300
  sleep 15
  wait_agent
fi

gexec 60 - nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
