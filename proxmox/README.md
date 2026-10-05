# Proxmox

The 3-node cluster: a custom desktop (`pve1`) plus two Asus i3 laptops
(`pve2`, `pve3`).

| Node | Machine | MGMT (VLAN 10) | CLUSTER (VLAN 60) | Switch port | Status |
| --- | --- | --- | --- | --- | --- |
| pve1 | desktop — Ryzen 5 5600 / 32GB / RTX 3060 | 10.10.10.11 | 10.10.60.11 | P2 | being built |
| pve2 | Asus i3-7 laptop, 12GB + USB NIC | 10.10.10.12 | 10.10.60.12 | P3 | installing |
| pve3 | Asus i3-7 laptop, 8GB + USB NIC | 10.10.10.13 | 10.10.60.13 | P4 | planned |

- Install procedure:
  [`../docs/runbooks/proxmox-install.md`](../docs/runbooks/proxmox-install.md).
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
