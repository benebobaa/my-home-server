# Network

Everything between the internet and the hypervisors.

| Path | Device | Managed with |
| --- | --- | --- |
| [`routeros/`](routeros/) | MikroTik hEX (RB750Gr3) — router / firewall / VLANs | OpenTofu |
| [`switch/`](switch/) | TP-Link SG108E — L2 switching / VLANs | web UI + config backups |
| [`cloudflare/`](cloudflare/) | Cloudflare — public DNS for `kubeletto.com` / `kubeletto.app`, the tunnel (ADR 0004) | OpenTofu |

Design and IP plan: [`../docs/design/network-design.md`](../docs/design/network-design.md).
