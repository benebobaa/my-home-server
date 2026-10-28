# traces — VictoriaTraces, the lab's trace store

Spans from the lab's apps, in CT 122 `traces` on pve1 (`10.10.10.20`, VLAN 10).
Why this product, this node and these ports: [ADR 0028](../../docs/decisions/0028-traces-victoriatraces-on-pve1.md).
How an app sends traces: [docs/standards/observability.md](../../docs/standards/observability.md), §2.

| | |
| --- | --- |
| Send (OTLP/HTTP) | `http://traces.home.arpa:10428/insert/opentelemetry/v1/traces` (JSON or protobuf) |
| Query | Grafana → Explore → **Traces** (data source `traces`, Tempo), **Drilldown → Traces**, or the dashboard *Trace store (VictoriaTraces)* |
| Built-in UI | `http://traces.home.arpa:10428/select/vmui` (MGMT only, no login) |
| Tempo API (Grafana's data source) | `http://traces.home.arpa:10428/select/tempo`: TraceQL search and metrics, what Traces Drilldown reads |
| Jaeger API | `http://traces.home.arpa:10428/select/jaeger` (the smoke test reads back through it) |
| Health | `http://traces.home.arpa:10428/health` (probed by `blackbox_http`, severity from `tier`) |
| Metrics | `http://traces.home.arpa:10428/metrics`: `vt_*` series (ingest, drops, disk) |
| Retention | 30 days, hard-capped at 16 GiB on a 20 GB disk: the oldest days go first |
| Built by | `proxmox/opentofu/traces.tf` → `setup.sh` (pinned release, sha256 of the tarball and of the binary) |
| Version | `TRACES_VERSION` in `setup.sh` (v0.12.1). **Pre-1.0 (v0.x):** the vendor documents its query paths as subject to change without notice. After every upgrade, re-run the smoke test and open the trace search panel |
| Alerts | `TracesNearDiskCap` (info, 14.5 GiB, [`rules/traces.yml`](../monitoring/prometheus/rules/traces.yml)); down is `TargetDown` / `HttpProbeFailed` |
| Backup | in the nightly PBS job (`--all`), so the main datastore on pve3 gets it. It may not hold it at steady state (about 5 GB free there, ADR 0025). Open: exclude it like CT 112, or accept the growth. The spans are 30 days, rebuildable from the senders |
| Logs | journald to the log store, like every guest (`logs: true`) |

## Who may send

- **MGMT** (VLAN 10): directly.
- **Other VLANs:** one exact hEX pinhole per sending host on 10428, the same pattern as `forward_logs_ingest`. Add it when the sender exists, in `network/routeros`, from `lab.yaml`. Not before: nothing in VLAN 20 is instrumented.
- **DMZ (Kubeletto):** not allowed. The DMZ never pushes into MGMT ([ADR 0008](../../docs/decisions/0008-observability-standard.md), [0013](../../docs/decisions/0013-ai-vm-off-the-tailnet.md)). Tenant traces need the ingest-only listener that ADR 0008 names as the upgrade path, or another decision by the operator.

## Smoke test

A span from MGMT, read back through the Jaeger API. Run it from the monitoring CT
(`pct exec 120`), so it proves the MGMT path:

```sh
TID=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
SID=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
NOW=$(date +%s%N)
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  http://10.10.10.20:10428/insert/opentelemetry/v1/traces --data-binary @- <<EOF
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"lab-smoke"}}]},
 "scopeSpans":[{"scope":{"name":"lab-smoke"},"spans":[{"traceId":"$TID","spanId":"$SID","name":"smoke-test",
 "kind":2,"startTimeUnixNano":"$NOW","endTimeUnixNano":"$NOW","status":{}}]}]}]}
EOF
sleep 20   # rows are buffered for a few seconds before they are queryable
curl -s "http://10.10.10.20:10428/select/jaeger/api/traces?service=lab-smoke&limit=1" | head -c 200
```

Expect `200`, then a JSON document with `"traceID"`. Ingest is not visible for a few
seconds after it returns 200 (`vt_pending_rows`).

## Gotchas

- The Service box on the trace dashboard holds a placeholder (`type-a-service`) that no service has, so the search shows *no data* until a sender exists.
- The smoke service `lab-smoke` stays until the 30-day retention drops it. It is a test record, not an app.
- The release's `-healthcheck` flag is not used: `/health` is what the monitoring block probes.

## Changing things

- **Any file here** → `tofu apply` in `proxmox/opentofu` (the targeted plan for `terraform_data.traces_setup`): it re-streams this directory and runs `setup.sh`. The binary is replaced only when its sha256 differs from the pinned one.
- **Upgrade:** bump `TRACES_VERSION`, `TRACES_TARBALL_SHA256` and `TRACES_BIN_SHA256` together, from the release's `_checksums.txt`. Check `/health` and the smoke test after.
- **Tier:** `standard` until an app depends on it; then `critical` in `lab.yaml`, as the shared services were (ADR 0028).
