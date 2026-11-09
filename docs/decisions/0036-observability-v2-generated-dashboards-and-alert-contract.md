# 0036 — Observability v2: generated dashboards, one alert contract, one SLO

**Status:** accepted (2026-11-09). Amends [ADR 0006](0006-monitoring-stack.md) (the pinned grafana.com dashboards) and [ADR 0008](0008-observability-standard.md) (the Service dashboard and the alert annotations). The stack itself does not change.

## Context

- **Dashboards.** 13 boards: 8 hand-written JSON files (2026-10-05 to 10-28) and 5 pinned from grafana.com. An audit on 2026-11-09 found that 32 of 68 alerts had no panel in the custom boards, two trace panels were always empty, and nothing but a pinned community board covered the router, the hosts or the WAN quota. Panel definitions were copied by hand between files, so units, thresholds and variables had drifted.
- **Data.** There is no kubelet/cAdvisor scrape (no per-pod CPU or memory, only requests), no request-rate/latency/error metric for Kubeletto core or larasrouter (only Traefik at the edge, whose service names are opaque hashes and whose histogram has 5 buckets), and no backup-freshness metric.
- **Alerts.** 49 of 68 rules never fired in 30 days, which is expected for guards (SMART, battery, quorum). The noisy ones: one cause (`ai` or `pve1` off) fires four alerts at once, and `ThinPoolFilling` on pve3 flapped 10 times around its threshold. Every rule has `summary` and `runbook_url` only, and the Kubernetes alerts sit under "Hosts" in `alerts.md`.
- **Tooling, researched 2026-11-09 from primary sources.** On Grafana 13 the GUI "Export" writes the v2 schema, which file provisioning rejects; the provisioning docs still show classic JSON. The Grafana Foundation SDK is "public preview" (v0.0.22), Grafonnet is "experimental, not for production", grafanactl is deprecated, and the Terraform provider needs an API token and state. The pinned promtool is 2.53.3 (the CT's Debian 13 release), so rules must stay compatible with it.
- **Storage.** The TSDB holds 4.1 GB for 30 days at about 2 bytes per sample. Prometheus has one retention per server, so a recording-rule rollup expires with the raw data and gives no longer history.

## Decision

1. **The stack stays:** Prometheus, Alertmanager, Grafana, VictoriaLogs, VictoriaTraces, Telegram, healthchecks.io.
2. **Dashboards are generated.** `scripts/dashboards/` (Python standard library only, PEP 723, run by `uv`) writes classic v1 JSON (`schemaVersion` 39) into `services/monitoring/grafana/dashboards/`, committed. `make check` regenerates and fails on any diff, enforces the rules of [docs/standards/dashboards.md](../standards/dashboards.md), and runs `dashboard-linter`. Nobody uses Grafana's GUI Export. Queries are derived from the upstream mixins (node, kubernetes, postgres, traefik) and the vendors' own boards, rewritten through the generator, each with its source and version in a comment.
3. **Grouping by concern**, one folder each: Overview (root), Infrastructure, Network, Platform services, Kubernetes, Applications, Observability. Resources follow USE, services follow RED.
4. **All 13 old boards are removed**, including the five from grafana.com. The provider uses `foldersFromFilesStructure` and `disableDeletion: false`, so removing a file removes its board. Dashboards deploy from their own `terraform_data`, so editing a board does not restart Prometheus or Grafana.
5. **The alert contract.** Every rule carries `summary`, `description`, `runbook_url` and `dashboard_url`. A check fails the build if any is missing, if a `runbook_url` anchor does not exist in `alerts.md`, or if a `dashboard_url` names a board that is not generated.
6. **One SLO** for Kubeletto: availability of the public API, SLI = the `blackbox_public` probes (synthetic, constant rate; Traefik 5xx would count client-cancelled uploads as outages), **99.5 % over 30 days** (3 h 36 min; the 2 h 20 min power cut of 2026-11-04 would have used about 65 %). Multiwindow multi-burn-rate alerts (14.4× over 1 h and 5 min, 6× over 6 h and 30 min, 1× over 3 d and 6 h), written by hand with promtool tests.
7. **Retention stays 30 days / 8 GB.** 90 days would need about 12 GB, more than the monitoring CT's whole disk. Capacity trends use `predict_linear` over the 30-day window.
8. **Data gaps are closed where the data proves a gap:** kubelet and cAdvisor from both k3s nodes (one generated hEX pinhole, a read-only token, a keep-list and sample limits), a backup-freshness series per guest (textfile collector), fewer wasted series (the zero `node_zfs_*` family, `node_systemd_unit_state`), and finer Traefik buckets with the router layer (rolled out only on the operator's go: it restarts the edge). App-level metrics for Kubeletto core and larasrouter are a separate follow-up.
9. **Meta-monitoring.** When `AlertmanagerNotificationsFailing` fires, Alertmanager also calls the healthchecks.io `/fail` endpoint, whose own Telegram integration is an independent path (a revoked bot token no longer fails silently). `info` alerts are muted when a stronger alert shares the cause. Flap-prone rules get `keep_firing_for`. Hosts that are off on purpose suppress their own reachability alerts, from a flag in `inventory/lab.yaml`.
10. **How changes reach the lab.** Work happens on a branch. Before every apply it is rebased onto the tip of `main`, and the apply runs from `main` or a descendant (the 2026-10-31 state split came from applying on two branches). One `tofu apply` in `proxmox/opentofu` pushes everything under `services/monitoring/`, rules included, so the commit body names any other session's changes that go live with it. Nothing is pushed without the operator.

## Consequences

- One generator holds units, thresholds, variables and links, and the checks keep every board and alert on one standard.
- The five community boards are gone. Their queries live on in the new boards where they were right, and the upstream version is recorded beside each.
- The generator and the dashboard linter (pre-1.0, v0.5.x) are new things to maintain. The linter's exclusions are listed with reasons in `.lint`.
- Grafana's file provider does not document what happens to an unmodified board when its file disappears. The first apply verifies it through the API.
- Rollups will not give a year of history. If that is ever wanted, it needs a second store or a larger disk, which is a new decision.

## Open

- Kubeletto core and larasrouter request/latency metrics (app instrumentation).
- Traefik's finer buckets and router layer, pending the operator's go and a quiet window.
- Derived fields from logs to traces, until an app emits `trace_id`.

## Verification

Filled in as each phase is applied. Decisions above are not edited by it.

**2026-11-09, boards (decisions 2, 3, 4 and 10).** Applied from a branch that was a descendant of `main`, with `-target` on the three monitoring resources, then on `terraform_data.monitoring_dashboards` alone for the second set. `terraform_data.ai_converge` was in the full plan (the hashes of `services/ai/converge.sh` and `provision.sh` differ from the recorded ones after another session's edits) and was left pending, as before; the `ai` VM was not touched.

- Grafana 13.2.3, through its API with the admin password only in the process environment: exactly the 17 generated boards in the root, Infrastructure, Network, Platform services, Kubernetes, Applications and Observability; every board loads and is provisioned; none of the old 13 remained (so `disableDeletion: false` works as intended, which Grafana's docs do not state for an unmodified board); the empty `Homelab` folder the old provider left was deleted.
- Datasources Prometheus, VictoriaLogs, Traces and the Jaeger fallback are healthy. `$__rate_interval` through Grafana's query API over the 60 s SNMP job returns 361 of 361 points, so the declared 30 s interval works.
- Every Prometheus query of every board was run against the live lab (`build.py --verify-live -v`): 0 errors and 0 unexpected empties, values read and checked, plus a 24 h range run for the time-series. The generator, the linter and the checks were proven with negative controls (a bad board, a hand-edited board, a stale file each fail `make check`); two bugs in my own guards were found that way and fixed (a `while` loop that reported only its last iteration, and a path split on a space).
- Series trimming (decision 8, first part): the relabel rules drop exactly 4,196 samples per scrape on the node job, as predicted from 3,020 + 1,176 series.
- `make check` passes on the final tree: 17 boards, linter clean, promtool, amtool, no leaks.

**Findings the boards surfaced, not decisions of this ADR:** five tenants cold-start 650 to 720 pods a day while customers send about 110 bit/s, so the worker's inbound is image pulls (`TenantWorkerInboundSustained` is firing); the monitoring CT's 24-day disk runway is the one-time fill of the 30-day window, with a predicted low near 2.4 GB free around 2026-11-15; the `pbs` datastore is at 84.8 %; pve3's thin pool sits at 85.02 %; `pbs-replica` (CT 112) is in no backup job; the ISP throttle holds the WAN near 4.9 Mbit/s, so `WanInboundDayHigh` cannot fire while it lasts.

**Not yet applied:** decisions 5 to 9 (the alert contract, the SLO, meta-monitoring, the remaining data gaps).
