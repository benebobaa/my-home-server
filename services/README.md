# Services (later)

What runs *inside* the guests — configs and compose files, one directory per
service.

Built:

- `admin-gw/` — Tailscale subnet router (MGMT LXC) — provisioned by OpenTofu
  (`proxmox/opentofu/`).
- `archive/` — File Browser (read-only) over Tailscale for the family archive
  (VLAN 20 LXC) — provisioned by OpenTofu.

Planned:

- `edge/` — Traefik + WireGuard tunnel (DMZ LXC).
- `monitoring/` — Uptime Kuma / Prometheus.
- `backends/` — production apps (VLAN 20).
