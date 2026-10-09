# Home Server Lab

Monorepo for the home lab — network, hypervisors, services and the public front.
Everything is reproducible from this repo.

> **Start here:** read [`docs/design/network-design.md`](docs/design/network-design.md)
> before touching anything.

## The stack

| Layer | What | Where |
| --- | --- | --- |
| Router / firewall | MikroTik hEX (RB750Gr3, RouterOS 7) | [`network/routeros/`](network/routeros/) |
| Switch | TP-Link SG108E (8-port managed) | [`network/switch/`](network/switch/) |
| Hypervisors | 3-node Proxmox cluster | [`proxmox/`](proxmox/) |
| Public front | VPS (HAProxy + WireGuard) | [`vps/`](vps/) |
| Services | edge proxy, admin, monitoring, apps | [`services/`](services/) |

## Layout

```text
docs/               # the knowledge: design, runbooks, decisions (ADRs)
network/            # the network: hEX (OpenTofu) + switch artifacts
proxmox/            # cluster + guests (later)
vps/                # public exposure host (later)
services/           # what runs on the guests (later)
ansible/            # host-level config management (later)
scripts/            # small helper scripts
```

## Principles

1. **Declarative first** — machines and networks are described in code
   (OpenTofu) and applied via `plan → review → apply`.
2. **One stack per target** — each stack is a self-contained directory with its
   own README, variables and state.
3. **Secrets never in git in plaintext** — credentials live in SOPS-encrypted
   `*.sops.env` files, OpenTofu state is encrypted (enforced); one age key
   decrypts everything. See [`docs/runbooks/secrets.md`](docs/runbooks/secrets.md).
4. **Document the why** — decisions become ADRs, procedures become runbooks.
5. **Snapshot before changes** — device configs are exported to `snapshots/`.

## Quickstart (router)

```sh
cd network/routeros
sops exec-env secrets.sops.env 'tofu plan'    # review the diff
sops exec-env secrets.sops.env 'tofu apply'   # commit it to the device
```

## Status

- [x] Repo structure, hEX OpenTofu scaffold, pre-reset snapshot
- [x] hEX reset + access bootstrap (SSH + REST verified; fresh snapshots in `network/routeros/snapshots/`)
- [x] hEX baseline: WAN + VLANs + DHCP + firewall (applied; `tofu plan` clean)
- [x] Switch VLAN configuration (SG108E; backup committed)
- [x] First client on VLAN 40: DHCP, DNS, internet, hEX + switch management verified
- [x] Proxmox: pve2 + pve3 (laptops) installed, Ansible-managed, clustered (`homelab`)
- [x] Remote admin: `admin-gw` (Tailscale subnet router) — OpenTofu
- [x] Remote admin HA (2026-10-09): `admin-gw2` on pve2, same routes; failover tested both ways (~1 min gap) ([RCA](docs/incidents/2026-10-09-remote-access-degraded.md))
- [x] GPUs (2× MX130): driver + boot-safe shared LXC passthrough ([ADR 0003](docs/decisions/0003-lxc-gpu-passthrough.md))
- [x] Foundation audit (2026-10-08): router NTP + MAC-access hardening, host cleanup, zero drift (`tofu plan` / `ansible --check`)
- [x] DMZ hardened as the tenant zone (2026-10-08): SMTP-25 and non-public egress blocked, 50/50 Mbps cap, exact pinholes; `home.arpa` names on the hEX
- [x] Old laptop HDDs triaged (2026-10-08): pve3's is failing (8,448 pending sectors) and its files were rescued by imaging ([runbook](docs/runbooks/disk-rescue.md)); pve2's is healthy and untouched
- [x] Family archive, interim (2026-10-09): per-person tree (`irene/ bene/ clara/ family/`) as the verified second copy on pve2's SSD; read-only File Browser over Tailscale for Bene + Irene ([ADR 0005](docs/decisions/0005-family-archive-over-tailscale.md), `services/archive/`). Not boot-safe yet
- [ ] Family archive, final: Irene's `Captures` re-encoded (~12 % size) so everything fits in two copies; then pve2's HDD becomes a ZFS pool (needs an explicit yes, destructive)
- [x] Monitoring (2026-10-09): Prometheus + Alertmanager + Grafana in CT 120 on pve2 (`10.10.10.16`, VLAN 10). It watches both nodes (SMART, thin pool, AC power, temperatures), the cluster (quorum, guests), the hEX over SNMPv3, and ping/HTTP/DNS reachability ([ADR 0006](docs/decisions/0006-monitoring-stack.md), `services/monitoring/`)
- [x] Alert channel (2026-10-09): Telegram (`@benehomeserver_bot`) for Alertmanager and Proxmox notifications; healthchecks.io check `homelab-watchdog` (5 min period + 5 min grace) as the dead-man's switch, pinged every minute by the Watchdog
- [x] Repo architecture for growth (2026-10-09, [ADR 0007](docs/decisions/0007-repo-architecture-for-growth.md)): pinned toolchain (`mise.toml`), `make check` + CI, secret scan in the hook; `inventory/lab.yaml` as the single source of addresses for both Tofu stacks; `modules/lxc-guest` (admin-gw, monitoring moved in, no rebuild). Next: Ansible inventory from `lab.yaml`, guest config as Ansible roles
- [x] Observability standard (2026-10-10, [ADR 0008](docs/decisions/0008-observability-standard.md), [the standard](docs/standards/observability.md)): every live host declares a `monitoring:` block in `lab.yaml` (CI fails without one); Prometheus targets and the hEX scrape/log rules are generated from it; alerts routed by severity (critical now, warning held overnight, info silent) with a runbook per alert ([alerts.md](docs/runbooks/alerts.md)); shared Service dashboard; logs from every node, container and the hEX in VictoriaLogs (CT 121 `logs`, 30 days / 6 GiB, `services/logs/`). New services start from `services/_template/`
- [ ] Foundation, before any stateful service: backups (PBS + test restore), UPS + clean shutdown, secrets (SOPS), encrypted IaC state, quorum tie-breaker
- [ ] Databases → apps
- [ ] Proxmox: pve1 (desktop, RTX 3060) — being built
- [ ] Public ingress via Cloudflare Tunnel ([ADR 0004](docs/decisions/0004-public-ingress-cloudflare-tunnel.md)): Cloudflare DNS as code, tunnel, Kubeletto move (VPS only on a trigger)
