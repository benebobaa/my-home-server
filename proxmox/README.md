# Proxmox

The 3-node cluster: a custom desktop (`pve1`) plus two Asus i3 laptops
(`pve2`, `pve3`).

| Node | Machine | MGMT (VLAN 10) | CLUSTER (VLAN 60) | Switch port | Status |
| --- | --- | --- | --- | --- | --- |
| pve1 | desktop — Ryzen 5 5600 / 32GB / RTX 3060 | 10.10.10.11 | 10.10.60.11 | P2 | being built |
| pve2 | Asus i3-7 laptop, 12GB + USB NIC | 10.10.10.12 | 10.10.60.12 | P3 | configured |
| pve3 | Asus i3-7 laptop, 8GB + USB NIC | 10.10.10.13 | 10.10.60.13 | P4 | configured |

- Install procedure:
  [`../docs/runbooks/proxmox-install.md`](../docs/runbooks/proxmox-install.md).
- **Guests are code:** new containers/VMs are provisioned with OpenTofu
  (`opentofu/`, bpg provider) — see [`opentofu/README.md`](opentofu/README.md).
- **Cluster:** `homelab` — pve2 + pve3 joined 2026-10-08 (corosync over
  VLAN 60, `10.10.60.12/13`). Formation + recovery notes:
  [`../docs/runbooks/proxmox-cluster.md`](../docs/runbooks/proxmox-cluster.md);
  pve1 joins when built.
- Node networking: VLAN-aware bridge on the trunk NIC (design §5). Management on
  VLAN 10, cluster on VLAN 60. No HA on the USB-NIC nodes (the laptops); the
  desktop node can carry HA later.
- Guest VLAN tags: 20 (SERVERS), 25 (DMZ), 30 (LAB).
- `pve1` build notes: enable SVM + IOMMU in BIOS (GPU passthrough for the
  RTX 3060 later); boot from an NVMe SSD.
- `pve1` runs **on-demand** (~4 days/week — electricity ≈ AI workstation):
  always-on services (edge, admin-gw, monitoring) belong on the laptops; AI
  training/serving runs on `pve1` while it is up. Wake-on-LAN from a laptop to
  start it remotely is planned.
- GPUs: both laptops carry an NVIDIA MX130 (Maxwell, `sm_50`) — tested working
  2026-10-08 (NVIDIA 580.178.04; pve3 also has CUDA 12.8). pve2 needs a one-time
  MOK enrollment (Secure Boot on) — experiment:
  [`../docs/experiments/mx130/`](../docs/experiments/mx130/), runbook:
  [`../docs/runbooks/secure-boot-mok.md`](../docs/runbooks/secure-boot-mok.md).
- `pve2` details: PVE 9.2, kernel 7.0.x. Single NIC = USB ASIX AX88179
  (Gigabit, pinned as `nic0`; no built-in Ethernet). Config snapshot in
  `nodes/pve2/interfaces`.
- `pve3` details: PVE 9.2, kernel 7.0.x. Single NIC = USB Gigabit adapter
  (pinned as `nic0`; no built-in Ethernet). Config snapshot in
  `nodes/pve3/interfaces`.
- Guests: add the admin SSH key at creation (the wizard has a field for it).
  Debian's default sshd refuses root *password* logins over SSH — key-only.
