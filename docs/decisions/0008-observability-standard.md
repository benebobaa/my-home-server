# 0008 — Observability standard: every host declares how it is watched, in lab.yaml; logs in VictoriaLogs

**Status:** accepted (2026-10-10)

## Context

Many apps are coming to the lab, starting with the Postgres container and
Kubeletto's K3s VM, then more. ADR 0006 gave the lab metrics and alerts. A
review before the apps arrive (2026-10-10) found four things that would turn
into chaos as hosts multiply:

1. **Targets were typed by hand.** Every host was added to `prometheus.yml`
   with its IP, and the hEX needed a matching firewall rule that someone had
   to remember. ADR 0007 had already named "the Prometheus targets" as the
   inventory's next consumer.
2. **Severity was ignored.** Every rule carried `severity`, but Alertmanager
   sent everything to Telegram at the same urgency. That is fine with 33
   rules and becomes alert fatigue with ten apps and one operator.
3. **No logs.** When something broke, the only record was the host's local
   journal, gone with the host.
4. **Nothing forced a new host to be watched.** It could go live and stay
   invisible.

The operator's direction: every app follows the home-server standard, not
the other way round (Kubeletto included, in a later session).

Constraints: pve2 has 12 GB and will host Kubeletto. Single operator.
Everything as code. Cost before production-readiness: don't over-gate.

Options considered for logs:

- **Loki + Promtail/Alloy:** label-based, Grafana-native, but an agent on
  every host (Promtail is end-of-life; Alloy is heavy for 512 MB guests).
- **OpenObserve:** what Kubeletto uses today; heavier, and its own UI and
  alerting beside Grafana/Alertmanager.
- **VictoriaLogs:** one small binary with a hard disk cap. It takes
  `systemd-journal-upload` natively (a Debian package, no agent to run) and
  syslog (the hEX). It has a signed Grafana plugin.

## Decision

**The contract lives in `inventory/lab.yaml`.** Every live host has a
`monitoring:` block (`tier`, optional `health` URL, `metrics` ports, `logs`)
or `monitoring: none` with a reason. `make inventory` (and so CI) fails
otherwise. From that one block:

- `proxmox/opentofu/monitoring.tf` generates the Prometheus targets (one
  file_sd file per job, pushed by `targets.py`). `prometheus.yml` holds no
  lab IP.
- `network/routeros` opens exactly the ports monitoring needs on hosts
  outside MGMT (`forward_monitoring_scrape`), and the log port for shippers
  outside MGMT (`forward_logs_ingest`).
- `logs: true` sets up log shipping (Tofu for containers, Ansible for the
  nodes).

**Severity is routed.** `critical` → Telegram now, repeated every 4 h.
`warning` → Telegram, held 23:00–07:00 WIB. `info` → Telegram without sound.
The generic alerts (`HostUnreachable`, `HttpProbeFailed`, `TargetDown`) take
their severity from the target's `tier`. Every rule has a `runbook_url` into
`docs/runbooks/alerts.md`.

**Per-guest resources come from the Proxmox API** (pve-exporter, already
running). No exporter inside guests unless the app has its own `/metrics`.

**Logs: VictoriaLogs in its own container, CT 121 `logs`** (pve2,
`10.10.10.18`, VLAN 10), 30 days hard-capped at 6 GiB. Its own container,
not CT 120: log volume depends on apps that do not exist yet, and a flood
must not starve Prometheus and alerting. Containers and nodes ship with
`systemd-journal-upload`. The hEX sends BSD syslog over UDP.

**Direction rule.** Monitoring pulls from any zone. Senders outside MGMT get
exactly one rule each, to the log store's ingest port. The DMZ never pushes
into MGMT: `lab.yaml` refuses `logs: true` there. DMZ apps are watched by
pull only.

**One shared Service dashboard** (Grafana, a picker over every host):
reachability, health, scrapes, firing alerts, guest resources, logs.

## Consequences

- Onboarding a host is a `lab.yaml` block plus `tofu apply` in both stacks.
  The checklist is `docs/standards/observability.md`; the starting point is
  `services/_template/`.
- **Accepted risk:** VictoriaLogs serves ingest and queries on the same port
  with no per-endpoint protection. A VLAN 20 host allowed to ship logs could
  also query every host's logs. VLAN 20 holds the operator's own services, not
  tenants, so this is accepted (cost first). This is a deliberate exception to
  design §8 "SERVERS cannot reach MGMT": one port, one host each. Upgrade
  path if a less trusted zone ever needs to ship: a syslog listener (ingest
  only) for that zone, or an ingest-only proxy in CT 121.
- A new container that ships logs must add its recreation marker to
  `local.guest_generation` (`logs.tf`); the plan fails until it does.
- `warning` alerts that fire and clear overnight are never sent. Grafana
  still shows them. That is the point.
- The hEX reports its identity `hex-lab` in syslog, not the inventory name
  `hex`. The dashboard matches syslog hosts by prefix.
- Not part of this standard yet, each with its trigger: tracing (when an app
  needs it), backup-age alerts (with PBS), external checks of public
  endpoints (with the first public app), per-host "stopped logging" alerts
  (would need vmalert; `LogsIngestionStopped` covers the store as a whole).
