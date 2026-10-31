# App standard

What every app in the lab provides and how it gets what it needs. Why:
[ADR 0010](../decisions/0010-shared-postgres-and-app-standard.md). It sits on
top of the [observability standard](observability.md) (how an app is
watched) and the backups (ADR 0009). Template:
[`services/_template/`](../../services/_template/).

Open on purpose: what apps run *on* (a container per app vs a shared
Docker/K3s host) is decided with the Kubeletto move. Everything below holds
either way.

## 1. Placement

| | Rule |
| --- | --- |
| Address, VMID, node | `inventory/lab.yaml` only (ADR 0007). Apps: VMID 200-299, VLAN 20 (`servers`), static IP `.10-.49` |
| Node | Holds state → pve2. Stateless or rebuildable → pve3 |
| Guest | `proxmox/opentofu/modules/lxc-guest`, built and configured as code (`services/<app>/setup.sh`, idempotent) |
| Size | Ask for what it uses, not what it might: pve2 has 12 GB for everything. Grow in place |

## 2. State

- An app's state lives on its guest's own disk (`disk_gb`), **not a bind
  mount**: vzdump skips bind mounts, so they are not backed up.
- Relational data goes in **the shared Postgres** (§3), not in a database
  inside the app's guest.
- A rebuild from code plus a restore from PBS must give back a working app.
  Anything not covered (a cache, a bind mount) is named in the app's README.

## 3. Database

One shared PostgreSQL 18, `postgres.home.arpa:5432` (CT 130,
[`services/postgres/`](../../services/postgres/README.md)):

- One database and one role per app, both named after the app. Add the
  name to `local.postgres_databases` in `proxmox/opentofu/postgres.tf`.
- Connect with TLS: `sslmode=require`. From VLAN 20 only.
- The app owns its schema and migrations; it gets no superuser and no access
  to another app's database.
- The database is dumped nightly and backed up with the CT; nothing for the
  app to do.

## 3a. Messaging and cache

Shared, like the database ([ADR 0016](../decisions/0016-shared-nats-and-valkey.md)):

- **NATS with JetStream**, `tls://nats.home.arpa:4222` (CT 131,
  [`services/nats/`](../../services/nats/README.md)): one account per app,
  with its JetStream limits and one user named after the app. Add it to
  `local.nats_accounts` in `proxmox/opentofu/nats.tf`. Pin the hub's
  certificate (`nats_tls_cert`). An app outside VLAN 20 runs its own leaf
  node and gets one exact hEX rule to 7422.
- **Valkey**, `valkey.home.arpa:<port>` (CT 132,
  [`services/valkey/`](../../services/valkey/README.md)): one instance per
  app (its own process, port, password, memory cap), TLS only (pin
  `valkey_tls_cert`, ADR 0017), **no persistence**. Add it to `local.valkey_instances` in
  `proxmox/opentofu/valkey.tf`. Anything that must survive a restart goes in
  Postgres or a JetStream stream, not in Valkey.

## 4. Secrets

- **Never in the repo in plain text, never in the guest image, never in
  argv or logs.** They reach the guest on stdin through the pinned root SSH
  (`ssh root@<node>` → `pct exec`), like `services/monitoring/secrets.sh`.
- **Generated** where possible (`random_password` in OpenTofu, encrypted
  state): database, NATS and Valkey passwords always are.
- **Given** (API tokens, third-party keys): in the stack's
  `secrets.sops.env`, passed as `TF_VAR_*` ([secrets runbook](../runbooks/secrets.md)).
- In the guest: a root-owned file readable only by the service's user, or
  systemd `LoadCredential=`.

## 5. Reaching it

| Audience | How |
| --- | --- |
| The operator, family | Tailscale (the admin gateways route VLAN 20). Default for every app |
| A teammate of one app | Tailscale under the tailnet policy (`network/tailscale/`): one address and port each, and a read-only role ([ADR 0029](../decisions/0029-teammates-read-only-on-the-tailnet.md)). Never an app's own credentials |
| The public | Only through Cloudflare Tunnel (ADR 0004), per hostname, as its own change |
| Other apps | Same VLAN directly; across VLANs only by an exact hEX rule (source, destination, port) |

No port forwards on the hEX, ever.

## 6. Observability and backups

Everything in [the observability standard](observability.md): the
`monitoring:` block, logs on stdout/stderr to the journal, a `/healthz` if
it has an HTTP side, no secrets in logs. A backup is automatic (§4 there).

## 7. Done means

The [onboarding checklist](observability.md#6-onboarding-checklist), plus:

- it survives `pct stop` / `pct start` with no hand step;
- its README says what it is, where its state lives, how it gets its
  secrets, and how to restore it;
- both OpenTofu stacks say `No changes`.
