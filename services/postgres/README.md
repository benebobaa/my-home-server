# postgres — the lab's shared PostgreSQL

One PostgreSQL 18 for every app: CT 130 `postgres` on pve2 (`10.10.20.21`,
`postgres.home.arpa`, VLAN 20). One database and one login role per app,
both named after the app. Why one shared instance and how:
[ADR 0010](../../docs/decisions/0010-shared-postgres-and-app-standard.md).
What an app must do to use it: [docs/standards/apps.md](../../docs/standards/apps.md).

| | |
| --- | --- |
| Version | PostgreSQL 18 from the PostgreSQL project's apt repo (PGDG, `trixie-pgdg`); 18.6 at build (2026-10-10). Major pinned in `setup.sh` (`PG_MAJOR`), minors from the repo |
| Cluster | `18/main`, UTF8, builtin `C.UTF-8` collation, data checksums on; 2 cores, 2 GB (`shared_buffers` 512 MB), 20 GB root disk |
| Apps connect | `postgres.home.arpa:5432`, database = user = `<app>`, `sslmode=require`, from VLAN 20 only |
| Admin | `ssh root@10.10.10.12` → `pct exec 130 -- runuser -u postgres -- psql` (peer auth; no superuser over the network) |
| Metrics | `postgres_exporter` on `:9187` (Debian package), role `prometheus` over the unix socket, no password. Alerts: `app-postgres.yml` |
| Logs | journal (`log_destination = syslog`, ident `postgres`) → VictoriaLogs: `_stream:{_HOSTNAME="postgres"} SYSLOG_IDENTIFIER:=postgres` |
| Backups | nightly PBS snapshot (02:30) **and** a logical dump at 01:30 WIB to `/var/backups/postgres/<UTC date>/`, last 3 kept there; PBS keeps the history |
| Built by | `proxmox/opentofu/postgres.tf` → `setup.sh`, `dump.sh` (installed as `pg-dump-all`), `roles.sh` |

## Giving an app a database

1. Add the app's name to `local.postgres_databases` in
   `proxmox/opentofu/postgres.tf` (`[a-z][a-z0-9_]*`; it is the database
   name and the role name).
2. In the app's own `.tf`, deliver the password into its guest the way
   `monitoring_secrets` delivers secrets (stdin through the pinned SSH, never
   argv, never a file in the repo):
   `random_password.postgres["<app>"].result`.
3. `tofu apply` in `proxmox/opentofu`: `roles.sh` creates the role and the
   database (owned by the role). The app connects with
   `postgres://<app>:<password>@postgres.home.arpa:5432/<app>?sslmode=require`.

The role owns its database and everything in it, and nothing else: it
cannot connect to another app's database (`pg_hba`: `sameuser`) or create
roles or databases.

**Rotate a password:** `tofu apply -replace='random_password.postgres["<app>"]'`;
`roles.sh` sets the new one and the app's secret step must re-run with it.

**Removing an app's database** is never automatic (removing the name from
`postgres.tf` leaves it, and `roles.sh` reports it as "present but not
declared"). Destructive, so a deliberate step: take a dump first
(`systemctl start pg-dump-all`), then
`DROP DATABASE <app>; DROP ROLE <app>;` as `postgres`.

## Access rules (`pg_hba`, written by `setup.sh`)

| From | To | How |
| --- | --- | --- |
| inside the CT, unix socket | anything | peer (OS user = role) |
| VLAN 20 (`10.10.20.0/24`) | only the database named after the role | TLS + scram-sha-256 |
| anywhere else | — | refused |

On top, the hEX lets nothing reach VLAN 20 except TRUSTED devices and the
admin gateways (which `pg_hba` then refuses), the monitoring scrape on 9187,
and the reserved K3s pinhole on 5432 (Kubeletto: add its `pg_hba` line when
that VM exists). Verified 2026-10-10: TLS 1.3 from VLAN 20; no-TLS,
other-database, wrong-password and MGMT (via admin-gw2) refused; MGMT
otherwise dropped by the hEX.

## Backups and restore

Two layers, both in the nightly PBS backup of CT 130:

- **The snapshot** of the whole disk. Crash-consistent: on restore Postgres
  replays its WAL like after a power cut. Tested 2026-10-10: CT 130 backed up
  live, restored to a scratch CT on pve3 without network, recovered in under
  a second, data present, 0 checksum failures.
- **The logical dump** (01:30): `globals.sql` (roles) + `<db>.dump` per
  database. Restores one app's database without touching the others, and
  across major versions. Tested 2026-10-10: table dropped, `pg_restore`
  brought back all rows with the right owner.

Restore one database from the newest local dump (inside the CT, as
`postgres`):

```bash
d=$(ls -1d /var/backups/postgres/20??-??-?? | tail -1)
pg_restore --clean --if-exists -d <app> "$d/<app>.dump"
```

Older than the last 3 nights: restore the CT from PBS to a scratch VMID
([backup-restore.md](../../docs/runbooks/backup-restore.md)) and take the
dump from its `/var/backups/postgres/`.

A failed dump shows in the journal only (`journalctl -u pg-dump-all`; also in
VictoriaLogs). The snapshot still covers the database.

## Upgrades

- **Minor (18.x):** `pct exec 130 -- apt-get update && apt-get install --only-upgrade postgresql-18`
  (restarts the server: a few seconds of refused connections). Record it in
  the commit body: it is not in the repo.
- **Major (19):** `pg_upgradecluster`, rehearsed first on a CT restored from
  PBS. Its own change, never a re-run of `setup.sh` with a new `PG_MAJOR`.

## Changing things

- **Config, access rules, dump schedule:** `setup.sh`, then `tofu apply`
  (restarts Postgres).
- **Size:** `cores` / `memory_mb` / `disk_gb` in `postgres.tf` (in place); keep
  `shared_buffers` at about a quarter of memory.

## Gotchas found while building

- The cluster is created by the package install, with the locale of the
  environment. The operator's Mac sends `LANG=en_US.UTF-8` over SSH, the
  container does not have it, and initdb fell back to `C`/**SQL_ASCII**.
  `setup.sh` now fixes the encoding and collation in
  `createcluster.d/homelab.conf` before the install, and fails if the
  cluster is anything else. An existing cluster is never re-created: if the
  check fails, rebuild the CT (`tofu apply -replace=module.postgres.proxmox_virtual_environment_container.this`)
  only while it holds no data.
- A new container's setup and its log shipping both ran `apt`, and one failed
  on the apt lock (`DPkg::Lock::Timeout` does not cover `apt-get update`).
  `log_shipping` in `logs.tf` now runs after each guest's setup.
- Debian's package writes `/var/log/postgresql/postgresql-18-main.log`; with
  `log_destination = syslog` only the startup lines before the config is read
  land there.
