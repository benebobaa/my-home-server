# _template — starting point for a new service

Copy this directory to `services/<name>/` and follow
[docs/standards/apps.md](../../docs/standards/apps.md) and
[docs/standards/observability.md](../../docs/standards/observability.md)
§6 (the onboarding checklist). A database comes from the shared Postgres
([services/postgres](../postgres/README.md#giving-an-app-a-database)). Nothing here is applied: it is not referenced
by any stack.

| File | Becomes |
| --- | --- |
| `lab.yaml.example` | the host's entry in `inventory/lab.yaml` |
| `guest.tf.example` | `proxmox/opentofu/<name>.tf` |
| `setup.sh` | `services/<name>/setup.sh`: in-guest install, idempotent |
| `alerts.yml.example` | `services/monitoring/prometheus/rules/app-<name>.yml` (only if the app needs its own alerts) |

Then write `services/<name>/README.md`: what it is, where it lives (VMID,
IP, node), how it is built, how to verify it, what to do when it breaks.
The existing services are good models: `services/monitoring/`,
`services/logs/`.
