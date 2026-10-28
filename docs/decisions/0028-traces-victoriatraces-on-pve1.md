# 0028 — Traces: VictoriaTraces in CT 122 on pve1, beside the log store's design

**Status:** accepted (2026-10-28). Decides the tracing item that [ADR 0008](0008-observability-standard.md) deferred ("tracing, when an app needs it"). ADR 0008 stands otherwise; it is not edited.

## Context

Metrics (Prometheus, CT 120) and logs (VictoriaLogs, CT 121) are in place. There is no trace store, so a request that crosses services (a Kubeletto request from the console through core, NATS, the deployer and K3s, or a query that is slow inside an app) can be seen only as metrics and log lines. The operator asked for traces now, not when an app first asks.

[ADR 0011](0011-kubeletto-on-the-home-cluster.md) removed OpenObserve, Vector and an OTel collector from the Kubeletto cluster on purpose: one observability stack, not two. A trace store is therefore one more service in the lab's own stack, and it should be built the way the log store is built.

Nothing in the lab emits traces yet. Kubeletto's core runs in the DMZ, and the DMZ never pushes into MGMT ([ADR 0008](0008-observability-standard.md), [ADR 0013](0013-ai-vm-off-the-tailnet.md)). Lab services on VLAN 20 are exporters only. So this decision builds the store and proves it end to end, and it decides how a sender gets in later.

## Decision

- **Product: VictoriaTraces, single-node build**, release v0.12.1 (the latest at the time), pinned by sha256 in `services/traces/setup.sh`. Same vendor and the same shape as VictoriaLogs: one binary, one data directory, a systemd unit, a pinned release. It speaks OTLP/HTTP for ingest and the Tempo API for Grafana, so Grafana uses its built-in Tempo data source. The Tempo API is also what Grafana's Traces Drilldown reads: TraceQL search and TraceQL metrics (RED).
- **Placement: CT 122 `traces` on pve1, at `10.10.10.20` (VLAN 10, MGMT).** pve1 is the always-on node with the NVMe disk ([ADR 0023](0023-pve1-always-on-ai-vm-on-demand.md)). pve2 has about 3 GB free and already carries the stateful guests, and [ADR 0025](0025-replica-backup-of-vm-300-on-pve1.md) set the precedent for stateful data on pve1. MGMT, beside the monitoring and log CTs, so Grafana (CT 120) reads it without a new router rule.
- **Ingest: OTLP/HTTP on `:10428`, path `/insert/opentelemetry/v1/traces`.** Senders in MGMT reach it directly. A sender in another VLAN needs one exact hEX pinhole per host, the same pattern as `forward_logs_ingest`, added when that sender exists. **The DMZ does not ship into MGMT.** Tenant traces from Kubeletto need the ingest-only listener that ADR 0008 names as the upgrade path, or a decision of their own. That is an operator decision, not made here.
- **Query: Grafana data source `traces`** (type `tempo`) at `http://traces.home.arpa:10428/select/tempo`. The built-in UI is at `/select/vmui`. The Jaeger API (`/select/jaeger`) stays up for the smoke test.
- **Standard:** `monitoring: { tier: standard, health, metrics: [10428], logs: true }`. Nothing depends on it yet. It becomes `critical` the day an app depends on it, as the shared services did ([ADR 0010](0010-shared-postgres-and-app-standard.md), [ADR 0016](0016-shared-nats-and-valkey.md)).
- **Retention:** 30 days, matching the log store (`-retentionPeriod=30d`), and a 16 GiB disk cap on the 20 GB disk (`-retention.maxDiskSpaceUsageBytes`, which the running v0.12.1 binary has). The oldest days go first when the cap is hit.

Rejected:

- **Grafana Tempo.** Designed around object storage, with more parts to run. A different family from VictoriaLogs for no gain at this size.
- **Jaeger with its own storage backend.** Another stateful service with its own storage, and no advantage over a single binary here.
- **OpenObserve.** Removed on purpose by ADR 0011. Bringing it back undoes the one-stack decision.
- **Not tracing.** The operator asked for it, and the cross-service questions above are the reason.

## Consequences

- **A stateful guest on pve1,** which breaks the "stateful guests on pve2" rule on purpose, the same as ADR 0025. Its disk is the NVMe that pve1 has.
- **No sender yet.** The store is proven with a smoke-test span from MGMT, not by a real request. The first real sender decides the pinhole (VLAN 20) or the DMZ listener (Kubeletto). Each of those is a separate decision and a separate change.
- **The app standard gains a tracing line** ([`docs/standards/observability.md`](../standards/observability.md), §2): an app with a request path exports OTLP traces to `traces.home.arpa` once its network path is decided.
- **Dashboards:** one trace-store health view (`platform-traces`). Per-service trace views wait for real traffic; a dashboard with no data is not added.
