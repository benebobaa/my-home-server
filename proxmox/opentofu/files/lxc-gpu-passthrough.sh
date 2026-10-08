#!/usr/bin/env bash
# Root-only container config: pass the host's NVIDIA GPU device nodes into an
# LXC container (shared — the host keeps using the GPU too; this is not
# VM/VFIO exclusive passthrough). Mirrors admin-gw-root-config.sh's pattern:
# devN: entries require genuine root@pam, API tokens cannot write dev* config.
#
# Prerequisite (host): ansible/proxmox-nodes.yml --tags gpu — loads
# nvidia_uvm/_drm/_modeset at boot and runs nvidia-persistenced, so the
# device nodes below exist before any container starts (an unprivileged LXC
# cannot load kernel modules itself).
#
# Usage: lxc-gpu-passthrough.sh <VMID>
# Idempotent: only adds devN entries that are missing; reboots the container
# only if something changed.
set -euo pipefail

VMID="${1:?usage: lxc-gpu-passthrough.sh <VMID>}"
CONF="/etc/pve/lxc/${VMID}.conf"

# Present on this hardware (GM108M / MX130, compute-only, no display
# attached to the card) — adjust if a future card exposes more
# (e.g. /dev/nvidia1 for a second GPU, /dev/nvidia-modeset for a card driving
# a display, /dev/dri/* for OpenGL/Vulkan).
DEVICES=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools)

changed=0
idx=0
for dev in "${DEVICES[@]}"; do
  [ -e "$dev" ] || { echo "skip: $dev not present on this host"; continue; }
  if grep -q "^dev${idx}: ${dev}\$" "$CONF" 2>/dev/null; then
    echo "dev${idx} already set to ${dev} on CT ${VMID}"
  else
    pct set "${VMID}" "-dev${idx}" "${dev}"
    echo "dev${idx} = ${dev} added to CT ${VMID}"
    changed=1
  fi
  idx=$((idx + 1))
done

if [ "$changed" -eq 1 ]; then
  echo "rebooting CT ${VMID} to apply"
  pct reboot "${VMID}"
fi
echo "done"
