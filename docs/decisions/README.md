# Decisions (ADRs)

Short, numbered notes: **context → decision → consequences**. Accepted ADRs are
never edited — supersede them with a new one.

| # | Decision |
| --- | --- |
| [0001](0001-opentofu-for-routeros.md) | OpenTofu as the IaC tool for RouterOS |
| [0002](0002-opentofu-for-proxmox-guests.md) | OpenTofu for Proxmox guests |
| [0003](0003-lxc-gpu-passthrough.md) | Shared LXC device passthrough for NVIDIA GPUs (not VM/VFIO) |
| [0004](0004-public-ingress-cloudflare-tunnel.md) | Public ingress through Cloudflare Tunnel; VPS path deferred |
| [0005](0005-family-archive-over-tailscale.md) | Family archive served over Tailscale node sharing, not Cloudflare Tunnel |
| [0006](0006-monitoring-stack.md) | Monitoring: Prometheus + Alertmanager + Grafana on VLAN 10, Telegram, external dead-man's switch |
| [0007](0007-repo-architecture-for-growth.md) | Repo architecture for growth: one inventory, an LXC module, Ansible for guest config |
| [0008](0008-observability-standard.md) | Observability standard: every host declares how it is watched in lab.yaml; severity routing; logs in VictoriaLogs (CT 121) |
