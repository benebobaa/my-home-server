# Runbook: giving an LXC container access to the NVIDIA GPU

**Applies to:** `pve2`, `pve3` (MX130, one per node). Shared passthrough —
the host and any number of other containers keep using the GPU too. See
`docs/decisions/0003-lxc-gpu-passthrough.md` for why this approach (not
VM/VFIO) and `docs/experiments/mx130/README.md` for how the host driver
itself got installed (dkms, Secure Boot off).

## 0. One-time host prerequisite (already applied)

```bash
cd ansible
ansible-playbook proxmox-nodes.yml --tags gpu,verify
```

This makes `nvidia_uvm`/`nvidia_drm`/`nvidia_modeset` load **at boot** (an
LXC cannot load kernel modules itself — on-demand loading, which is what
happens when you run a CUDA app directly on the host, does not work from
inside a container), enables `nvidia-persistenced`, and — the part that's
easy to miss — runs `nvidia-modprobe -c0 -u` at boot to actually **create**
`/dev/nvidia-uvm[-tools]`. Loading the module is not enough by itself: this
driver ships no udev rule for that device node, so without the explicit
mknod step the node only appears after the first CUDA app happens to run as
real root on the host. Confirmed by a cold reboot of both nodes
(2026-10-08): before this fix, `/dev/nvidia-uvm` was missing on boot even
though `nvidia_uvm` was loaded; after it, the node exists before any manual
command runs. Re-run any time; it's idempotent. A new GPU node needs
`has_nvidia_gpu=true` added in `ansible/inventory.ini` first.

## 1. Create the container (however you normally do — OpenTofu or `pct create`)

Nothing GPU-specific here. Any unprivileged or privileged LXC works.

## 2. Pass the device nodes through

```bash
scp proxmox/opentofu/files/lxc-gpu-passthrough.sh root@<node>:/root/
ssh root@<node> bash /root/lxc-gpu-passthrough.sh <VMID>
```

Adds `dev0..3` (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`,
`/dev/nvidia-uvm-tools`) to `/etc/pve/lxc/<VMID>.conf` and reboots the
container if anything changed. Root-only (same limitation as `admin-gw`'s
`dev0` TUN passthrough — the OpenTofu API token cannot write `dev*` config).

## 3. Install the matching driver **inside** the container (userspace only)

The container needs the exact same driver version as the host — it shares
the host's kernel module, so only the userspace libraries + `nvidia-smi` are
needed:

```bash
# copy the same .run file used on the host (kept in /root/mx130-experiment/
# on both nodes), then inside the container:
sh NVIDIA-Linux-x86_64-580.178.04.run -s -z \
  --no-kernel-module --no-nvidia-modprobe --skip-depmod --no-systemd
```

## 4. Verify

```bash
pct exec <VMID> -- nvidia-smi          # should show the MX130
```

## Gotchas

- **DHCP may not get a lease** on a fresh container on the MGMT VLAN
  (default-deny firewall) — use a static IP (`pct set <VMID> -net0
  name=eth0,bridge=vmbr0,tag=10,ip=<addr>/24,gw=10.10.10.1`) if so.
- **Installer needs headroom to decompress**: give the container at least
  ~2 GB RAM while installing (it was OOM-killed at 1 GB); turn it back down
  afterward if the guest's normal workload doesn't need it.
- **Driver version drift:** upgrading the host driver means reinstalling the
  matching userspace package in every GPU-enabled container.
- **No isolation between containers:** this is shared passthrough — any
  container with the devices can use the full 2 GB VRAM; there's no quota.
  Watch for concurrent heavy jobs on the same card.
- `/dev/nvidia-modeset` *does* now exist (created automatically once
  `nvidia_modeset` loads at boot, unlike `nvidia-uvm` — DRM/KMS modules get a
  udev rule, this vendor module doesn't) but isn't passed through by the
  script above and isn't needed for compute-only (CUDA) workloads; add
  `dev4: /dev/nvidia-modeset` yourself if a guest ever needs display output.

## Validated (2026-10-08)

- Built a throwaway unprivileged CT (`pct create` + the steps above) on
  `pve2`, confirmed `nvidia-smi` and a CUDA `vectoradd` run matched
  bare-metal numbers exactly (24.80 ms/rep, 32.5 GB/s, verify OK), then
  destroyed it (`pct stop && pct destroy`) — this runbook is the
  reproduction path, nothing was left running.
- **Cold-rebooted both pve2 and pve3** afterward specifically to check the
  host prerequisite survives a real boot, not just "still loaded from
  earlier testing" — this is what caught the missing `nvidia-modprobe -c0 -u`
  step above. After the fix, both nodes show `/dev/nvidia-uvm[-tools]`
  present immediately on boot, before any CUDA command runs.

## Revert

```bash
pct stop <VMID>
for n in 0 1 2 3; do pct set <VMID> -delete dev${n}; done
pct start <VMID>
```
