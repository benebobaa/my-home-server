#!/usr/bin/env bash
# ai — the on-demand AI workstation VM on pve1 (ADR 0012), defined as a root
# script instead of a bpg resource.
#
# Why a script: pve1 is off most days, and the PVE API cannot read an
# offline node (every /nodes/pve1/... call fails with "proxy handler
# failed"). A provider resource on pve1 would break `tofu plan` and
# `make drift` whenever it is off. terraform_data (proxmox/opentofu/ai.tf)
# runs this over the pinned root SSH only when the script, the user-data or
# the inventory values change; a plan reads nothing remote. Trade-off: plan
# does not see drift on this VM; re-running this script converges it.
# The GPU passthrough (hostpci) is root-only anyway.
#
# Idempotent: creates the VM once (disk imported from a pinned cloud image),
# then re-applies the settings below on every run. A running VM is never
# restarted: changes that need it show up as pending (`qm pending`).
#
# Arguments (from inventory/lab.yaml): vmid name cidr gateway vlan
set -euo pipefail

VMID=${1:?usage: vm.sh <vmid> <name> <cidr> <gateway> <vlan>}
NAME=${2:?}
CIDR=${3:?}
GATEWAY=${4:?}
VLAN=${5:?}

# Ubuntu 24.04 LTS cloud image, a dated release pinned by the SHA256SUMS
# Ubuntu publishes next to it.
IMG_URL=https://cloud-images.ubuntu.com/releases/noble/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img
IMG_SHA256=6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2
IMG=/var/lib/vz/import/ubuntu-24.04-server-cloudimg-amd64-20260926.qcow2

GPU=0000:0b:00   # RTX 3060, both functions (bound to vfio-pci: Ansible `vfio`)
CORES=10         # of 12 threads; the host keeps 2
MEMORY=24576     # MiB, all pinned while running (VFIO): no ballooning
DISK=250G        # OS, models, datasets; thin pool is 337 GB
STORAGE=local-lvm

if ! qm status "$VMID" >/dev/null 2>&1; then
  if ! echo "${IMG_SHA256}  ${IMG}" | sha256sum -c --status 2>/dev/null; then
    echo "ai: downloading the cloud image"
    install -d /var/lib/vz/import
    curl -fsSL -o "${IMG}.part" "$IMG_URL"
    echo "${IMG_SHA256}  ${IMG}.part" | sha256sum -c --quiet
    mv "${IMG}.part" "$IMG"
  fi

  echo "ai: creating VM ${VMID}"
  qm create "$VMID" \
    --name "$NAME" \
    --description "ai — on-demand AI workstation, RTX 3060 by passthrough (ADR 0012). Managed by services/ai/vm.sh via proxmox/opentofu/ai.tf." \
    --tags "ai;gpu;tofu" \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:0,import-from=${IMG},discard=on,ssd=1,iothread=1,backup=0" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --net0 "virtio,bridge=vmbr0,tag=${VLAN}"
  qm disk resize "$VMID" scsi0 "$DISK"
fi

# Converged on every run (cheap, idempotent). The VM is on demand (ADR 0023):
# onboot 0, so it does not start with pve1. Running this script starts it.
qm set "$VMID" \
  --cpu host \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --balloon 0 \
  --onboot 0 \
  --agent enabled=1 \
  --hostpci0 "${GPU},pcie=1" \
  --ipconfig0 "ip=${CIDR},gw=${GATEWAY}" \
  --nameserver "$GATEWAY" \
  --searchdomain home.arpa \
  --cicustom "user=local:snippets/${NAME}-user-data.yaml"

# On demand (ADR 0023): this script never starts the VM. The operator starts it
# with `qm start` when learning AI.
if [ "$(qm status "$VMID" | awk '{print $2}')" != running ]; then
  echo "ai: VM ${VMID} is stopped (on demand); start it with: qm start ${VMID}"
elif qm pending "$VMID" | grep -qE '^(new|del) '; then
  echo "ai: VM ${VMID} is running with pending changes; they apply at its next restart:"
  qm pending "$VMID" | grep -v '^cur' || true
fi

qm status "$VMID"
