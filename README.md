# Home Server Lab

Living repo for a home lab: network design + infrastructure as code.

| Device | Role | Status |
| --- | --- | --- |
| MikroTik hEX (RB750Gr3, RouterOS 7) | router / firewall / VLAN gateway | in setup |
| TP-Link SG108E | managed switch | pending |
| Proxmox cluster (M720q + 2 laptops) | hypervisors | later |
| VPS | public front for exposed services | later |

The original network design draft lives in [`initial.md`](initial.md); it is
being revised against the real hardware as we build.

## Layout

```text
initial.md              # network design draft (v2)
routeros/               # MikroTik hEX
  bootstrap.rsc         # one-time access-layer script (template, no secrets)
  bootstrap.local.rsc   # ready-to-paste version with real credentials (git-ignored)
  snapshots/            # /export dumps captured before changes
  *.tf                  # OpenTofu — the actual router config lives here
  .env                  # ROS_* credentials for the provider (git-ignored)
switch/                 # SG108E port map + config backups (later)
proxmox/                # cluster + guest definitions (later)
vps/                    # public exposure setup (later)
```

## Conventions

- **Declarative first** — the hEX config is owned by OpenTofu; changes go
  `plan → review → apply`, never ad-hoc clicking.
- **Thin bootstrap** — only identity, admin user, OOB network and the REST API
  are applied by hand (`routeros/bootstrap.rsc`); the rest is in `routeros/*.tf`.
- **No secrets in git** — `.env`, `*.local.rsc` and `*.tfstate` are ignored.
- **Snapshot before changes** —
  `ssh ben@192.168.88.1 '/export' > routeros/snapshots/hex-<date>.rsc`.

## Current state

- hEX reachable on `192.168.88.1` (user `ben`), RouterOS 7.23.7 long-term.
- Household LAN discovered: `192.168.18.0/24` — no overlap with the lab ranges.
- Pre-reset snapshot: `routeros/snapshots/hex-2026-10-05-pre-reset.rsc`.
- Next: clean reset → bootstrap → OpenTofu baseline (WAN, VLANs, DHCP, firewall).
