# Services (later)

What runs *inside* the guests — configs and compose files, one directory per
service.

Planned:

- `edge/` — Traefik + WireGuard tunnel (DMZ LXC).
- `admin-gw/` — Tailscale subnet router (MGMT LXC).
- `monitoring/` — Uptime Kuma / Prometheus.
- `backends/` — production apps (VLAN 20).
