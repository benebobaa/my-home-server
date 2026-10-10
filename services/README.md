# Services (later)

What runs *inside* the guests — configs and compose files, one directory per
service.

Built:

- `admin-gw/` — Tailscale subnet router (MGMT LXC) — provisioned by OpenTofu
  (`proxmox/opentofu/`).
- `archive/` — File Browser (read-only) over Tailscale for the family archive
  (VLAN 20 LXC) — provisioned by OpenTofu.
- `monitoring/` — Prometheus, Alertmanager, Grafana + exporters (VLAN 10 LXC)
  — provisioned by OpenTofu.
- `logs/` — VictoriaLogs, the lab log store (VLAN 10 LXC).
- `pbs/` — Proxmox Backup Server, nightly backups of every guest (VLAN 10 LXC, pve3).
- `postgres/` — the shared PostgreSQL 18, a database per app (VLAN 20 LXC).

New services start from `_template/` and follow `docs/standards/` (apps,
observability).

Planned:

- `edge/` — Traefik + WireGuard tunnel (DMZ LXC).
- `backends/` — production apps (VLAN 20).
