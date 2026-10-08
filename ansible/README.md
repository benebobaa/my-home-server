# Ansible — node configuration

Source of truth for the **Proxmox host** configuration (the layer between the
hardware and the guests). The guests are OpenTofu (`proxmox/opentofu/`); the
router is OpenTofu (`network/routeros/`); this playbook owns what was
previously applied by hand during node setup.

Idempotent — `--check --diff` doubles as a drift report.

## Usage

```bash
cd ansible
ansible-playbook proxmox-nodes.yml --check --diff   # drift report (no changes)
ansible-playbook proxmox-nodes.yml                  # converge
ansible-playbook proxmox-nodes.yml --limit pve3     # single node
ansible-playbook proxmox-nodes.yml --tags upgrade   # explicit full upgrade
```

## What it manages

| Setting | Where it comes from |
| --- | --- |
| apt repos (enterprise off, no-subscription on) | this playbook |
| lid-switch ignore (`logind.conf`) | this playbook |
| sleep/suspend targets masked | this playbook |
| `usbcore.autosuspend=-1` in GRUB | this playbook |
| `/etc/network/interfaces` (VLAN-aware trunk) | `proxmox/nodes/<node>/interfaces` |
| NIC pinning (`.link` → `nic0`) | `pve_nic_mac` per host in `inventory.ini` |
| root `authorized_keys` (admin key) | `~/.ssh/id_ed25519.pub` on the operator machine |
| NVIDIA modules load at boot + `nvidia-persistenced` (`--tags gpu`) | hosts with `has_nvidia_gpu=true` in `inventory.ini` — see `docs/runbooks/gpu-lxc-passthrough.md` |

## What it verifies (read-only asserts)

FQDN, USB NIC speed (must be 1000 Mb/s), autosuspend active in the running
kernel, sleep masked, `pveversion` report.

## Notes

- Changing `/etc/network/interfaces` needs a **reboot** — the playbook warns
  instead of rebooting on its own.
- `/root/.ssh/authorized_keys` is a PVE-managed symlink to
  `/etc/pve/priv/authorized_keys` (cluster-shared); the playbook ensures the
  key is present, not the link's mode.
- `pve2` joins the inventory; run it once the node is networked again.
- Reinstall path (future): `proxmox/nodes/<node>/answer.toml` for PVE 9
  unattended installs + this playbook for post-install.
- Not managed here: the Proxmox API user/token bootstrap (one-time, by
  design — see `proxmox/opentofu/README.md`) and the SG108E switch (no
  provider — backup + runbook).
- Swapping a node's NIC: update `pve_nic_mac` and run the playbook **while the
  node is still reachable**, then swap the hardware and reboot — no console
  visit needed. A node that is already dark needs one console session — that
  is the bootstrap path (the same reason install media exist), not a gap in
  the IaC.
- Cluster formation is a guarded one-time task (`--tags cluster`, tag
  `never`): creates on the node with `cluster_creator=true`, joins the rest
  with `--use_ssh`. See `docs/runbooks/proxmox-cluster.md` for the gotchas
  (password-default join, guests-present check).
