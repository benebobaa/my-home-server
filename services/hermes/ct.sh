#!/usr/bin/env bash
# hermes — the personal agent's container on pve1 (ADR 0018), defined as a
# root script instead of a bpg resource, for the reason in services/ai/vm.sh:
# pve1 is off most days and the PVE API cannot read an offline node, so a
# provider resource there would break `tofu plan` whenever it is off.
# terraform_data (proxmox/opentofu/hermes.tf) runs this over the pinned root
# SSH only when this script or the inventory values change.
#
# Idempotent: creates the container once from the pinned Debian template,
# then re-applies the settings below on every run. A running container is
# never restarted: resource limits apply live, the rest at its next start.
#
# Arguments (from inventory/lab.yaml): vmid name cidr gateway vlan
set -euo pipefail

VMID=${1:?usage: ct.sh <vmid> <name> <cidr> <gateway> <vlan>}
NAME=${2:?}
CIDR=${3:?}
GATEWAY=${4:?}
VLAN=${5:?}

# Same template as the lxc-guest containers (proxmox/opentofu/archive.tf),
# from Proxmox's appliance index; plain HTTP, so the sha512 is checked.
TEMPLATE=debian-13-standard_13.6-1_amd64.tar.zst
TEMPLATE_URL=http://download.proxmox.com/images/system/${TEMPLATE}
TEMPLATE_SHA512=4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b
TEMPLATE_PATH=/var/lib/vz/template/cache/${TEMPLATE}

CORES=2        # a ceiling, not a reservation
MEMORY=2048    # MiB; Hermes' install builds its TUI with Node
SWAP=512       # MiB
DISK=10        # GiB: Debian + Hermes' own Python, Node and venv
STORAGE=local-lvm

if ! pct status "$VMID" >/dev/null 2>&1; then
  if ! echo "${TEMPLATE_SHA512}  ${TEMPLATE_PATH}" | sha512sum -c --status 2>/dev/null; then
    echo "hermes: downloading the Debian template"
    install -d "$(dirname "$TEMPLATE_PATH")"
    curl -fsSL -o "${TEMPLATE_PATH}.part" "$TEMPLATE_URL"
    echo "${TEMPLATE_SHA512}  ${TEMPLATE_PATH}.part" | sha512sum -c --quiet
    mv "${TEMPLATE_PATH}.part" "$TEMPLATE_PATH"
  fi

  echo "hermes: creating container ${VMID}"
  # Unprivileged; nesting as in modules/lxc-guest (systemd in unprivileged
  # containers). No SSH key: nothing routes to it from the Mac, the operator
  # enters it from pve1 (`pct enter`).
  pct create "$VMID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$NAME" \
    --description "hermes — personal agent (Hermes Agent, Telegram), on demand with pve1 (ADR 0018). Managed by services/hermes/ct.sh via proxmox/opentofu/hermes.tf." \
    --tags "agent;tofu" \
    --ostype debian \
    --unprivileged 1 \
    --features nesting=1 \
    --rootfs "${STORAGE}:${DISK}"
fi

# Converged on every run (cheap, idempotent).
pct set "$VMID" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --onboot 1 \
  --net0 "name=eth0,bridge=vmbr0,tag=${VLAN},ip=${CIDR},gw=${GATEWAY}" \
  --nameserver "$GATEWAY" \
  --searchdomain home.arpa

if [ "$(pct status "$VMID" | awk '{print $2}')" != running ]; then
  echo "hermes: starting container ${VMID}"
  pct start "$VMID"
fi

pct status "$VMID"
