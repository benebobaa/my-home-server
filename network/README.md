# Network

Everything between the internet and the hypervisors.

| Path | Device | Managed with |
| --- | --- | --- |
| [`routeros/`](routeros/) | MikroTik hEX (RB750Gr3) — router / firewall / VLANs | OpenTofu |
| [`switch/`](switch/) | TP-Link SG108E — L2 switching / VLANs | web UI + config backups |

Design and IP plan: [`../docs/design/network-design.md`](../docs/design/network-design.md).
