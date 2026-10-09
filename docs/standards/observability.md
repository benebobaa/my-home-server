# Observability standard

What every host and app in the lab provides, and what it gets in return.
Why: [ADR 0008](../decisions/0008-observability-standard.md). Template:
[`services/_template/`](../../services/_template/).

The rule: **every live host in `inventory/lab.yaml` declares how it is
watched.** `make check` fails otherwise, in CI too.

## 1. The `monitoring:` block

```yaml
  myapp:
    kind: lxc
    vmid: 201
    node: pve2
    vlan: servers
    ip: 10.10.20.40
    note: what it is (services/myapp)
    monitoring:
      tier: standard                       # critical | standard | best-effort
      health: "http://{ip}:8080/healthz"   # optional; {ip} = this host's IP
      metrics: [8080]                      # optional; scraped at /metrics
      logs: true                           # ship the journal to the log store
```

Or `monitoring: none`, with the reason in `note`.

| Field | Rule |
| --- | --- |
| `tier` | **critical**: down = something important is broken now, page any hour. **standard**: should work; a warning, held overnight. **best-effort**: info only (no sound). |
| `health` | An HTTP endpoint that answers **2xx only when the app works** (its database reachable, etc.), cheaply, without auth. UIs that answer 401 or a redirect: add `health_module: http_any`. |
| `metrics` | Only if the app already serves Prometheus `/metrics`. Don't add an exporter just for this: CPU, memory, disk and network per guest come from the Proxmox API for free. |
| `logs` | `true` for every guest that runs systemd. **Not allowed in the DMZ**: the DMZ never pushes into MGMT. |

## 2. What the app must do

- **Log to stdout/stderr** under systemd (or to the journal). One line per
  event; JSON lines are welcome (VictoriaLogs unpacks them at query time:
  `| unpack_json`). No log files of its own.
- **Never log secrets** (tokens, passwords, full request bodies). Logs are
  readable by whoever can query the store.
- **Serve `/healthz`** if it has an HTTP side (see `health` above).
- **Hostname = inventory name.** `modules/lxc-guest` sets it; don't change it.
  Logs, alerts and the dashboard join on it.

## 3. What it gets, with no further work

| | Where |
| --- | --- |
| Ping + health probe, alerts with severity from `tier` | `HostUnreachable`, `HttpProbeFailed`, `TargetDown` |
| `PveGuestDown` if it should run (`start_on_boot`) and doesn't | cluster rules |
| Scrape of its `/metrics`, labelled `instance`, `service`, `tier` | job `service` |
| Its logs, 30 days | Grafana → Explore → VictoriaLogs: `_stream:{_HOSTNAME="myapp"}` |
| The Service dashboard (pick the host) | Grafana → Homelab → Service |
| The hEX rules for the above, if it lives outside MGMT | generated in `network/routeros/firewall.tf` |

## 4. Optional, when the app is worth it

- **App alerts:** `services/monitoring/prometheus/rules/app-<name>.yml`. Every
  rule needs `severity` (`critical` / `warning` / `info`), a `summary`, and a
  `runbook_url` to a section in `docs/runbooks/alerts.md` (or the app's own
  runbook). `make check` runs `promtool` on it.
- **App dashboard:** `services/monitoring/grafana/dashboards/app-<name>.json`,
  datasource uids `prometheus` and `victorialogs`.

## 5. Onboarding checklist

1. Add the host with its `monitoring:` block to `inventory/lab.yaml`;
   `make inventory`.
2. Build the guest (`modules/lxc-guest`; start from `services/_template/`).
   If `logs: true`, add its recreation marker to `local.guest_generation` in
   `proxmox/opentofu/logs.tf`.
3. `tofu apply` in `network/routeros` (DNS name, firewall rules), then in
   `proxmox/opentofu` (guest, targets, log shipping). Router changes: snapshot
   before and after (`./scripts/hex-snapshot.sh`).
4. Verify:
   - Prometheus → Targets: its targets `up`.
   - The Service dashboard shows it, including logs.
   - Stop its service once: `HttpProbeFailed` fires (silence it first if
     it's the middle of the night).
5. `make check`, update the service README, commit.

## 6. Severity and routing

| severity | Telegram | When |
| --- | --- | --- |
| `critical` | immediately, with sound; repeated every 4 h while firing | someone should act now, at any hour |
| `warning` | with sound, but held 23:00–07:00 WIB | act today; resolved overnight → never sent |
| `info` | silent message | a record (a reboot, a cap reached) |

`Watchdog` never reaches Telegram: it is the healthchecks.io dead-man's
switch.
