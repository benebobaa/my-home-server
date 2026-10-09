# 0006 — Monitoring: Prometheus + Alertmanager + Grafana on VLAN 10, Telegram, external dead-man's switch

**Status:** accepted (2026-10-09)

## Context

The lab had no monitoring and no alert channel (README Status, foundation
items). What had already gone wrong, or could, without anyone noticing:

- pve3's HDD failed with 8,448 pending sectors, found by chance.
- The two-node cluster loses quorum when either node is down, which locks
  management.
- pve2's guest thin pool was at 69 %, and guests freeze at 100 %.
- Power cuts: the nodes are laptops on battery, the hEX is not.

Constraints:

- **Small hardware.** pve2 has 4 cores and 12 GB, and Kubeletto (K3s) is moving
  in (ADR 0004). Budget: about 1.5 GB RAM and 12 GB disk.
- **The whole house can go dark at once.** It sits behind CGNAT on one power
  feed, and anything that watches from inside dies with it. Design §7
  already requires an external check.
- Everything as code, converged from the repo (AGENTS.md).

Options considered:

- **Uptime Kuma alone:** up/down only. No history, SMART, thin-pool or
  quorum data.
- **Netdata:** a heavy agent on every node, and pushes towards its cloud.
- **Zabbix:** needs its own database server, too heavy here.
- **Prometheus + Alertmanager + Grafana:** an exporter exists for every
  target (node, PVE API, SNMP, blackbox). Alert rules live in files. The
  "always-firing Watchdog → external dead-man's switch" pattern is native.
  VictoriaMetrics would be a drop-in if disk ever gets tight; at about 20
  targets and 12k series it isn't needed.

## Decision

- **One unprivileged LXC, CT 120 `monitoring`, on pve2** (stateful-guest
  placement), static `10.10.10.16` on **VLAN 10 (MGMT)**. Design §7 allowed
  VLAN 10 or 20. MGMT wins because the nodes' exporters are on MGMT with no
  router hop, and an observer of the infrastructure belongs with PBS and
  admin-gw. From VLAN 20 it would need pinholes into MGMT.
- Prometheus (30 d / 8 GB), Alertmanager, blackbox_exporter, snmp_exporter
  and node_exporter come **from Debian 13 packages**. Grafana comes from its
  signed apt repo, pinned and held. prometheus-pve-exporter is pinned in a
  venv. Dashboards are pinned by grafana.com revision and sha256.
- **Hosts:** node_exporter on the MGMT IP only (not the VLAN 60 cluster link),
  plus Debian's SMART and LVM textfile collectors (Ansible `monitoring`
  tag).
- **PVE API:** a read-only `PVEAuditor` token, created on pve2 by root and
  written straight into the CT. It never leaves the cluster.
- **hEX:** SNMPv3 authPriv, read-only, answering only `10.10.10.16`. The
  input chain admits UDP 161 from that address only. The factory `public`
  community is adopted and disabled. The monitoring host may ping other
  VLANs and the switch (ICMP only).
- **Alerts:** one destination, a **Telegram** bot. Proxmox's own
  notifications (backup jobs, fencing) use the same chat through a PVE
  webhook target. **healthchecks.io** receives the Watchdog every minute and
  alerts on its own when the pings stop.
- Grafana requires a login. Prometheus and Alertmanager have none and are
  reachable from MGMT, TRUSTED and admin-gw only, over plain HTTP. On these
  segments the transport is the LAN or Tailscale's encrypted tunnel. This
  is accepted the same way as the other MGMT UIs.

## Consequences

- Monitoring lives on pve2, so pve2 going down takes it down too. That case
  is covered by the external dead-man's switch, not by a second Prometheus.
- While the internet is down, Telegram alerts queue and arrive afterwards.
  healthchecks.io will already have alerted.
- The SNMPv3 passwords exist in both stacks' `secrets.sops.env` (the router
  sets them, the exporter uses them): rotate both together
  (`docs/runbooks/secrets.md`).
- New scrape targets in other VLANs need an exact hEX rule per exporter port.
  ICMP is already allowed.
- The Telegram and healthchecks.io accounts are operator steps
  (`services/monitoring/README.md`). Until they exist, alerts route to a
  blackhole receiver.
- Next: backup-age alerts with PBS, an external HTTP check of the public
  tunnel with ADR 0004, hEX remote syslog (design §9), UPS via NUT.
