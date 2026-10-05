# Proxmox

The 3-node cluster. First node is an old laptop (`pve2`); the M720q (`pve1`)
follows later.

| Node | Machine | MGMT (VLAN 10) | CLUSTER (VLAN 60) | Switch port | Status |
| --- | --- | --- | --- | --- | --- |
| pve1 | M720q | 10.10.10.11 | 10.10.60.11 | P2 | planned |
| pve2 | laptop + USB NIC | 10.10.10.12 | 10.10.60.12 | P3 | installing |
| pve3 | laptop (future) | 10.10.10.13 | 10.10.60.13 | P4 | planned |

- Install procedure:
  [`../docs/runbooks/proxmox-install.md`](../docs/runbooks/proxmox-install.md).
- Node networking: VLAN-aware bridge on the USB NIC (design §5). Management on
  VLAN 10, cluster on VLAN 60. No HA on USB-NIC nodes; corosync only once
  ≥2 nodes exist.
- Guest VLAN tags: 20 (SERVERS), 25 (DMZ), 30 (LAB).
