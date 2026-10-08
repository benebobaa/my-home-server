# 0003 — Shared LXC device passthrough for NVIDIA GPUs (not VM/VFIO)

**Status:** accepted (2026-10-08)

## Context

The MX130 experiment (`docs/experiments/mx130/README.md`) proved both laptop
GPUs work under NVIDIA's driver. The next question: how should *guests*
(containers/VMs) actually consume the GPU, reproducibly, so a future service
(transcoding, local inference, etc.) can just ask for it?

Options considered:

- **LXC device passthrough (shared):** bind-mount the host's `/dev/nvidia*`
  nodes into one or more containers. The host driver stays loaded and
  in control; several containers can use the same card concurrently (no
  exclusive lock). Containers need the matching NVIDIA **userspace** driver
  installed (`--no-kernel-module`) — no separate kernel module, no separate
  Secure-Boot/MOK/dkms story per guest.
- **VM passthrough (VFIO):** give one VM the whole PCI device exclusively
  (IOMMU `vfio-pci` bind, nouveau/nvidia unloaded from the host). The host
  loses the GPU entirely while the VM holds it; only one guest at a time.
- **NVIDIA vGPU:** needs a datacenter-class card + licensing — not available
  on GeForce (MX130, and the planned RTX 3060).

## Decision

Default to **LXC device passthrough, shared**, provisioned by:

- `ansible/proxmox-nodes.yml` (`--tags gpu`) — host readiness: `nvidia_uvm` /
  `nvidia_drm` / `nvidia_modeset` load at **boot** (not on first CUDA call —
  an LXC cannot load kernel modules itself), `nvidia-persistenced` enabled,
  and `/dev/nvidia-uvm[-tools]` explicitly created at boot (`nvidia-modprobe
  -c0 -u` — this driver ships no udev rule for it; confirmed missing on a
  cold reboot before this was added).
- `proxmox/opentofu/files/lxc-gpu-passthrough.sh <VMID>` — adds the `devN:`
  entries to a container (root-only, same class of limitation as `admin-gw`'s
  `dev0` TUN passthrough: the Terraform/OpenTofu API token cannot write
  `dev*` config).
- Inside the container: install the **same-version** driver `.run` with
  `--no-kernel-module` (userspace libs + `nvidia-smi` only).

Full runbook: `docs/runbooks/gpu-lxc-passthrough.md`.

VM/VFIO stays a documented alternative, not set up, for if a guest ever needs
**exclusive** use of a card (losing host + other-container access). Validated
as feasible now: each MX130 sits alone in its own IOMMU group. Revisit when
`pve1`'s RTX 3060 is ready — a bigger, higher-value card is the more likely
candidate for being reserved to one VM.

## Consequences

- Any number of containers can share one GPU; there is no VRAM/compute quota
  between them (2 GB total — mind concurrent workloads).
- Every container needs the exact host driver version's userspace package —
  a host driver upgrade means re-installing it in each GPU-enabled guest.
- The host must boot the GPU-relevant kernel modules even when no guest is
  using them yet (small, fixed memory cost; no measurable power cost — the
  card still runtime-suspends idle).
- This path gives up the option of a VM exclusively owning a card without
  first removing the shared setup (unloading the modules the host depends on
  for other containers).
