# Dashboard standard

What every Grafana board in the lab provides. Why: [ADR 0036](../decisions/0036-observability-v2-generated-dashboards-and-alert-contract.md). The host and app side of observability: [observability.md](observability.md).

Boards are **generated**, never edited by hand and never saved from the UI:
`scripts/dashboards/` writes `services/monitoring/grafana/dashboards/<Folder>/<name>.json`, `make dashboards` regenerates, and `make check` fails when the committed JSON differs from the generator's output. Do not use Grafana's GUI "Export" on Grafana 13: it emits the v2 schema, which file provisioning rejects.

## 1. Who reads a board, and how

| Mode | Where | The board must answer |
| --- | --- | --- |
| **Triage** | a phone, after a Telegram alert (each alert links its board) | what is broken, and where to look next, in about 10 seconds |
| **Review** | the Mac, about 15 minutes a week | what is trending toward a problem (runway, growth, quota) |

## 2. Structure

- **Folders by concern:** Overview (root), Infrastructure, Network, Platform services, Kubernetes, Applications, Observability. A board belongs to one folder; its neighbours are one click away through the `homelab` tag links.
- **Method:** resources follow **USE** (utilisation, saturation, errors), services follow **RED** (rate, errors, duration). The board says which in its tags (`use`, `red`, `overview`).
- **Layout:** the top row is the answer: 4 to 8 stat panels that turn green or red against the same thresholds the alerts use. Below it, one collapsible row per question, about 5 panels each. A board has at most about 25 panels.
- **Every panel** has a title, a description (what it shows, how to read it, what bad looks like), a unit, and thresholds or none on purpose. No pie charts. No stacked series unless the parts sum to a whole. Rates start at 0.

## 3. Queries

- Rate windows use `$__rate_interval`, never a literal `[5m]`. The Prometheus data source declares a 30 s scrape interval so the window is at least 2 minutes, enough for the 60 s SNMP job.
- Thresholds that mirror an alert come from the same number as the rule. The comment names the rule.
- Host selection is a variable (`$instance`), never a hardcoded host.
- Data sources are the fixed uids `prometheus`, `victorialogs`, `traces`, `alertmanager`.
- A query adapted from an upstream mixin or a vendor board carries its source and version in the generator's source comment.

## 4. Identity

| Field | Rule |
| --- | --- |
| `uid` | `homelab-<token>-<name>`, token by folder: `infra`, `net`, `platform`, `k8s`, `apps`, `obs` (the Overview is `homelab-overview`) |
| `tags` | `homelab`, the folder, the method |
| `description` | the question the board answers, and when to open it |
| `schemaVersion` | 39 (Grafana migrates up on load) |
| `editable` | false |

## 5. Alerts and boards

Every alert rule's `dashboard_url` names a generated board (`/d/<uid>`). The board has a panel for what the rule measures, and the panel's description names the rule. `make check` fails when a `dashboard_url` points at a board that is not generated.

## 6. Changing a board

1. Edit the Python under `scripts/dashboards/boards/` (or the helpers in `lib.py`).
2. `make dashboards`, then `scripts/dashboards/build.py --verify-live` (every query is run against the live Prometheus; an error or an empty result is listed).
3. `make check`, commit the generator change and the JSON together.
4. `tofu apply` in `proxmox/opentofu` pushes the boards (they have their own step: no service restarts).
