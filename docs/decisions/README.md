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
| [0009](0009-backups-pbs-on-pve3.md) | Backups: Proxmox Backup Server in a container on pve3, nightly, every guest; the archive's bind mounts not yet covered |
| [0010](0010-shared-postgres-and-app-standard.md) | One shared PostgreSQL 18 (CT 130) for the lab's apps, a database + role per app; databases get an exporter; the app standard |
| [0011](0011-kubeletto-on-the-home-cluster.md) | Kubeletto runs on the home K3s cluster: tunnel-only edge, free tier boxed for a household IP, one observability stack, prod-data copies operator-only |
| [0012](0012-pve1-on-demand-ai-workstation.md) | pve1 is an on-demand AI workstation: the RTX 3060 goes whole to one Ubuntu VM by VFIO; no always-on services; its guests are scripts (the API cannot read an offline node) |
| [0013](0013-ai-vm-off-the-tailnet.md) | The `ai` VM stays off the tailnet and ships no logs: reached through the admin gateways' route; untrusted-code zones never push into MGMT |
| [0014](0014-gpu-metrics-and-lab-as-untrusted-zone.md) | GPU metrics from nvidia_gpu_exporter (basic driver readings, no profiling counters); the LAB is an untrusted zone for monitoring like the DMZ |
| [0015](0015-tenant-capacity-by-measured-reservations.md) | Tenant capacity at home: reservations sized to measured use (40 warm pods on the 4 GB worker), no new hardware, no second worker, no pve1 worker |
