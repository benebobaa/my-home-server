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
| [0016](0016-shared-nats-and-valkey.md) | Shared NATS with JetStream (CT 131, an account per app, a leaf node for apps outside VLAN 20) and Valkey (CT 132, a process per app, cache only); Kubeletto moves onto them after its cutover check |
| [0017](0017-valkey-clients-pin-the-certificate.md) | Valkey's certificate comes from OpenTofu and clients pin it (Kubeletto: `REDIS_TLS_CA`); supersedes 0016's skip-verify stance |
| [0018](0018-personal-agent-on-pve1.md) | The personal agent (Hermes Agent, Telegram, OpenCode Go models) runs on pve1 on demand, in a plain unprivileged LXC on the LAB VLAN; native install, no Docker; it can read its own keys (accepted) |
| [0019](0019-temporary-llm-serving-bench-lab.md) | Temporary LLM serving bench lab (until the article): `llm-bench` CT 201 on VLAN 20, one pinhole to `ai:8000`, node_exporter + engine metrics on `ai`, an internet kill switch for `ai` |
| [0020](0020-ai-vm-without-docker.md) | The `ai` VM runs without Docker or the NVIDIA container toolkit; engines run natively in `uv` venvs (supersedes 0012's Docker line) |
