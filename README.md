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
- [x] Family archive, interim (2026-10-09): per-person tree (`irene/ bene/ clara/ family/`) as the verified second copy on pve2's SSD; read-only File Browser over Tailscale for Bene + Irene ([ADR 0005](docs/decisions/0005-family-archive-over-tailscale.md), `services/archive/`). Mount sources in fstab (`nofail`) since 2026-10-15, boot path not yet proven by a cold reboot
- [ ] Family archive, final: Irene's `Captures` re-encoded (~12 % size) so everything fits in two copies; then pve2's HDD becomes a ZFS pool (needs an explicit yes, destructive)
- [x] Monitoring (2026-10-09): Prometheus + Alertmanager + Grafana in CT 120 on pve2 (`10.10.10.16`, VLAN 10). It watches both nodes (SMART, thin pool, AC power, temperatures), the cluster (quorum, guests), the hEX over SNMPv3, and ping/HTTP/DNS reachability ([ADR 0006](docs/decisions/0006-monitoring-stack.md), `services/monitoring/`)
- [x] Alert channel (2026-10-09): Telegram (`@benehomeserver_bot`) for Alertmanager and Proxmox notifications; healthchecks.io check `homelab-watchdog` (5 min period + 5 min grace) as the dead-man's switch, pinged every minute by the Watchdog
- [x] Repo architecture for growth (2026-10-09, [ADR 0007](docs/decisions/0007-repo-architecture-for-growth.md)): pinned toolchain (`mise.toml`), `make check` + CI, secret scan in the hook; `inventory/lab.yaml` as the single source of addresses for both Tofu stacks; `modules/lxc-guest` (admin-gw, monitoring moved in, no rebuild). Next: Ansible inventory from `lab.yaml`, guest config as Ansible roles
- [x] Observability standard (2026-10-10, [ADR 0008](docs/decisions/0008-observability-standard.md), [the standard](docs/standards/observability.md)): every live host declares a `monitoring:` block in `lab.yaml` (CI fails without one); Prometheus targets and the hEX scrape/log rules are generated from it; alerts routed by severity (critical now, warning held overnight, info silent) with a runbook per alert ([alerts.md](docs/runbooks/alerts.md)); shared Service dashboard; logs from every node, container and the hEX in VictoriaLogs (CT 121 `logs`, 30 days / 6 GiB, `services/logs/`). New services start from `services/_template/`
- [x] Backups (2026-10-10, [ADR 0009](docs/decisions/0009-backups-pbs-on-pve3.md)): Proxmox Backup Server in CT 111 on pve3; nightly job (02:30) covers every guest automatically; prune 7d/4w/6m, verify weekly; failures → Telegram; restore tested (CT 120 → scratch CT, Prometheus history intact) ([runbook](docs/runbooks/backup-restore.md)). The family archive's files are not backed up (bind mounts), by the operator's decision: the archive was meant to be temporary (deletion planned 2026-10-12); the operator kept it running on 2026-10-15
- [ ] Foundation, before any stateful service: UPS + clean shutdown, quorum tie-breaker, off-site backup copy (secrets/SOPS and encrypted IaC state are done)
- [x] Database (2026-10-10, [ADR 0010](docs/decisions/0010-shared-postgres-and-app-standard.md)): one shared PostgreSQL 18.6 in CT 130 `postgres` on pve2 (`10.10.20.21`, VLAN 20), a database + role per app with OpenTofu-generated passwords; TLS + `sameuser` from VLAN 20 only; exporter + alerts, logs in VictoriaLogs; nightly logical dump plus the PBS snapshot, both restores tested (`services/postgres/`). The [app standard](docs/standards/apps.md) says what every app must do
- [x] Messaging and cache (2026-10-14, [ADR 0016](docs/decisions/0016-shared-nats-and-valkey.md)): shared NATS 2.15 with JetStream in CT 131 `nats` on pve2 (`10.10.20.22`, an account per app, TLS with a pinnable OpenTofu-generated certificate, leaf nodes for apps outside VLAN 20) and Valkey 8.1 in CT 132 `valkey` on pve3 (`10.10.20.23`, a process per app, TLS only, no persistence); exporters, alerts (`app-nats.yml`, `app-valkey.yml`), logs. Proven from VLAN 20 across nodes, including a JetStream-less leaf with Kubeletto's 12 × 500 MB streams. Open: Kubeletto's switch after its cutover check ([runbook](services/nats/README.md#kubelettos-switch-after-the-cutovers-24-hour-check))
- [ ] Apps (first ones onboarded through the app standard; what they run on is decided with the Kubeletto move)
- [x] Proxmox: pve1 (2026-10-13, desktop, Ryzen 5 5600 / 32 GB / RTX 3060): installed, converged by Ansible, joined `homelab` as the 3rd node; GPU bound to `vfio-pci` for one VM, Wake-on-LAN armed ([install runbook](docs/runbooks/proxmox-install.md#desktop-node-pve1)). On demand ([ADR 0012](docs/decisions/0012-pve1-on-demand-ai-workstation.md)): woken by Wake-on-LAN, one silent alert while off
- [x] AI workstation (2026-10-13): VM 140 `ai` on pve1, Ubuntu 24.04, RTX 3060 by passthrough, NVIDIA 580 + CUDA 13.0 + Docker GPU runtime, LAB VLAN, off the tailnet ([ADR 0013](docs/decisions/0013-ai-vm-off-the-tailnet.md), [`services/ai/`](services/ai/README.md)). Reached from the Mac as `ssh bene@10.10.30.10` through the admin gateways (route approved and tested 2026-10-13)
- [x] Personal agent (2026-10-16, [ADR 0018](docs/decisions/0018-personal-agent-on-pve1.md)): CT 141 `hermes` on pve1 (LAB VLAN, `10.10.30.11`), Hermes Agent v0.22.2 with its Telegram gateway (@hermes_benelabs_bot, operator only), OpenCode Go models (`glm-5.3-flash`); online while pve1 is up ([`services/hermes/`](services/hermes/README.md)). Proven: the operator's Telegram messages answered (4–6 s), a terminal tool call, the gateway back by itself after a container reboot. Open: a pve1 cold wake with the bot
- [x] LLM serving bench lab, **temporary** (2026-10-25, [ADR 0019](docs/decisions/0019-temporary-llm-serving-bench-lab.md)): CT 201 `llm-bench` on pve2 (`10.10.20.40`, GuideLLM + lm-eval) → `ai:8000` through one hEX pinhole; node_exporter and engine metrics on `ai`, `/data`, snapshot `bench-baseline`, an internet kill switch for `ai`. Proven: bench → `:8000` works, `ai` → lab VLANs times out, scrapes up, kill switch blocks and Tofu ignores the flip. Torn down after the article ([teardown](services/llm-bench/README.md#teardown-after-the-article))
- [x] Kubeletto home ([ADR 0004](docs/decisions/0004-public-ingress-cloudflare-tunnel.md), [ADR 0011](docs/decisions/0011-kubeletto-on-the-home-cluster.md), [ADR 0015](docs/decisions/0015-tenant-capacity-by-measured-reservations.md)): **cut over on 2026-10-14** (database swapped 13:44, 52 tenant services restored, DNS flipped 14:15 WIB; the rented server stays as the rollback until 2026-11-05). Cloudflare DNS as code and the tunnel, K3s on VMs 300/301, `services/kubeletto/` for the database copy, secrets snapshot, restore and image steps, `network/cloudflare/flip.sh` for the gapless flip. Record, timings and what went wrong: [cutover checklist](docs/runbooks/kubeletto-cutover.md#cutover-record-2026-10-14-done-no-notice-sent). Hardening 2026-10-15 ([architecture](docs/design/kubeletto-architecture.md)): inbound allow-lists on both K3s VMs, alerts for the platform's pods and its public path (incl. the registry token endpoint), VM 300 restore drill passed, console redeployed; the rented server is quiet (CronJobs suspended, tenant pods stopped) with a wipe script ready. Open: the switch onto the shared NATS/Valkey (prepared, after the 24 h check), deleting Aiven and Upstash after 7 days (operator's yes), registry retention at home (dry run done), the rented server's wipe before 2026-11-05, one tenant app that cannot move
