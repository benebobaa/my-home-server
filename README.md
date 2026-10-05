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
3. **Secrets never in git** — credentials live in local `.env` files
   (git-ignored); state files stay local.
4. **Document the why** — decisions become ADRs, procedures become runbooks.
5. **Snapshot before changes** — device configs are exported to `snapshots/`.

## Quickstart (router)

```sh
cd network/routeros
set -a; source .env; set +a    # ROS_USERNAME / ROS_PASSWORD
tofu plan                      # review the diff
tofu apply                     # commit it to the device
```

## Status

- [x] Repo structure, hEX OpenTofu scaffold, pre-reset snapshot
- [x] hEX reset + access bootstrap (SSH + REST verified; fresh snapshots in `network/routeros/snapshots/`)
- [x] hEX baseline: WAN + VLANs + DHCP + firewall (applied; `tofu plan` clean)
- [x] Switch VLAN configuration (SG108E; backup committed)
- [ ] Proxmox cluster + edge services
- [ ] VPS public exposure
