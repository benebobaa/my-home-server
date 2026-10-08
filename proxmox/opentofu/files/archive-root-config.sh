#!/usr/bin/env bash
# Root-only container config for archive (CT 110 on pve2):
#   mp0 = the family archive, read-only        -> /srv/archive
#   mp1 = re-encoded Zoom recordings, read-only -> /srv/archive/irene/zoom-recordings
#   dev0 = /dev/net/tun (Tailscale)
#
# Host bind mounts and dev* need genuine root@pam — API tokens cannot write
# them, so OpenTofu invokes this over SSH (see ../archive.tf).
#
# Interim sources (until the archive moves to ZFS, services/archive/README.md):
# /mnt/staging = thin LV pve/rescue-staging, /mnt/e4 = pve2 HDD sda4. Neither
# is in fstab; refuse to bind an unmounted path (it would show an empty dir).
#
# Idempotent: reboots the container only when something actually changed.
set -euo pipefail

VMID=110
CONF="/etc/pve/lxc/${VMID}.conf"
MP0_SRC=/mnt/staging/archive
MP1_SRC=/mnt/e4/_captures-30fps

for m in /mnt/staging /mnt/e4; do
  mountpoint -q "$m" || { echo "ERROR: $m is not mounted on $(hostname)" >&2; exit 1; }
done
# mp1's target must exist inside the read-only mp0 (LXC cannot mkdir there).
mkdir -p "${MP0_SRC}/irene/zoom-recordings"

changed=0
want() { # key value
  if ! grep -qxF "$1: $2" "$CONF"; then
    pct set "$VMID" "-$1" "$2"
    changed=1
  fi
}
want mp0 "${MP0_SRC},mp=/srv/archive,ro=1"
want mp1 "${MP1_SRC},mp=/srv/archive/irene/zoom-recordings,ro=1"
want dev0 "/dev/net/tun"

if [ "$changed" = 1 ]; then
  echo "CT ${VMID} config changed; rebooting to apply"
  pct reboot "$VMID"
else
  echo "CT ${VMID} already configured; nothing to do"
fi
