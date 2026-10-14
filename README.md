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
- [x] Backups (2026-10-10, [ADR 0009](docs/decisions/0009-backups-pbs-on-pve3.md)): Proxmox Backup Server in CT 111 on pve3; nightly job (02:30) covers every guest automatically; prune 7d/4w/6m, verify weekly; failures → Telegram; restore tested (CT 120 → scratch CT, Prometheus history intact) ([runbook](docs/runbooks/backup-restore.md)). The family archive's files are not backed up (bind mounts), by the operator's decision: the archive is temporary and will be deleted on 2026-10-12
- [ ] Foundation, before any stateful service: UPS + clean shutdown, quorum tie-breaker, off-site backup copy (secrets/SOPS and encrypted IaC state are done)
- [x] Database (2026-10-10, [ADR 0010](docs/decisions/0010-shared-postgres-and-app-standard.md)): one shared PostgreSQL 18.6 in CT 130 `postgres` on pve2 (`10.10.20.21`, VLAN 20), a database + role per app with OpenTofu-generated passwords; TLS + `sameuser` from VLAN 20 only; exporter + alerts, logs in VictoriaLogs; nightly logical dump plus the PBS snapshot, both restores tested (`services/postgres/`). The [app standard](docs/standards/apps.md) says what every app must do
- [ ] Apps (first ones onboarded through the app standard; what they run on is decided with the Kubeletto move)
- [x] Proxmox: pve1 (2026-10-13, desktop, Ryzen 5 5600 / 32 GB / RTX 3060): installed, converged by Ansible, joined `homelab` as the 3rd node; GPU bound to `vfio-pci` for one VM, Wake-on-LAN armed ([install runbook](docs/runbooks/proxmox-install.md#desktop-node-pve1)). On demand ([ADR 0012](docs/decisions/0012-pve1-on-demand-ai-workstation.md)): woken by Wake-on-LAN, one silent alert while off
- [x] AI workstation (2026-10-13): VM 140 `ai` on pve1, Ubuntu 24.04, RTX 3060 by passthrough, NVIDIA 580 + CUDA 13.0 + Docker GPU runtime, LAB VLAN, off the tailnet ([ADR 0013](docs/decisions/0013-ai-vm-off-the-tailnet.md), [`services/ai/`](services/ai/README.md)). Reached from the Mac as `ssh bene@10.10.30.10` through the admin gateways (route approved and tested 2026-10-13)
- [ ] Kubeletto home ([ADR 0004](docs/decisions/0004-public-ingress-cloudflare-tunnel.md), [ADR 0011](docs/decisions/0011-kubeletto-on-the-home-cluster.md), **deadline 2026-11-05**): Cloudflare DNS as code; tunnel `kubeletto-home` live with Origin-CA trust; K3s on VMs 300/301 with anti-spoofing firewall; rehearsal phase 1 (2026-10-11) and the home build, phase 2 (2026-10-12: free-tier limits, custom domains through Cloudflare for SaaS, a GitHub-built deploy), are done (`services/kubeletto/`). Phase 3 prep (2026-10-14): scheduler alerts for the cluster (kube-state-metrics) and the prod-to-home database copy rehearsed end to end ([runbook](docs/runbooks/kubeletto-migration.md#cutover-database-and-state)). Phase 3 proofs run early (2026-10-14): cold reboot of both nodes, a PBS restore of the database CT, the worker's measured ceiling (28 warm tenant pods, 40 after right-sizing the reservations) and the scheduler alerts firing for real ([results](docs/runbooks/kubeletto-migration.md#phase-3-rehearsal-results-2026-10-14)); the cutover is written as one ordered checklist ([kubeletto-cutover.md](docs/runbooks/kubeletto-cutover.md)). Worker capacity settled without hardware (40 warm tenant pods, measured). Open: the operator's yes for a full tenant restore, then the cutover (Oct 30 - Nov 1)
