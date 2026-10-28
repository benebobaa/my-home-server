#!/usr/bin/env bash
# Format (if blank) and mount the registry disk on the K3s server VM
# (proxmox/opentofu/k3s.tf, scsi1). Run in the guest as root; idempotent.
# It refuses a disk that carries anything but our own label.
set -euo pipefail

DEV=/dev/sdb
LABEL=registry
MNT=/mnt/registry

[ -b "$DEV" ] || { echo "registry-disk: $DEV is missing (scsi1 not attached?)" >&2; exit 1; }
if findmnt -rn -S "$DEV" >/dev/null && ! findmnt -rn -S "LABEL=$LABEL" >/dev/null; then
  echo "registry-disk: $DEV is mounted elsewhere" >&2; exit 1
fi

have=$(blkid -s LABEL -o value "$DEV" 2>/dev/null || true)
if [ -z "$(blkid "$DEV" 2>/dev/null || true)" ] && [ -z "$(lsblk -n -o NAME "$DEV" | sed 1d)" ]; then
  echo "registry-disk: $DEV is blank, formatting ext4 ($LABEL)"
  mkfs.ext4 -q -L "$LABEL" "$DEV"
elif [ "$have" != "$LABEL" ]; then
  echo "registry-disk: $DEV carries something else (label '${have}'), refusing" >&2; exit 1
fi

mkdir -p "$MNT"
grep -q "^LABEL=$LABEL " /etc/fstab || echo "LABEL=$LABEL $MNT ext4 defaults,nofail,discard 0 2" >> /etc/fstab
systemctl daemon-reload
findmnt -rn "$MNT" >/dev/null || mount "$MNT"
mkdir -p "$MNT/data"
chmod 0755 "$MNT/data"
findmnt -rn -o TARGET,SOURCE,FSTYPE,SIZE "$MNT"
df -h "$MNT" | tail -1
