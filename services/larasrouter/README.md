# larasrouter on the shared Postgres and Valkey

> **Pinholes pending.** They were applied, then removed after a probe that turned out
> to be a pod-startup race (ADR 0022, Follow-up). They go back with the operator's
> apply once the residual (a few seconds per pod start) is accepted.

[ADR 0022](../../docs/decisions/0022-a-tenant-app-uses-the-shared-postgres-and-valkey.md).
larasrouter runs on Kubeletto as tenant `f42a6fae` (account `larasrouter@gmail.com`,
namespace `kl-f42a6fae-f42a6fae`, services `larasrouter-api` and `larasrouter-mock-llm`).

| What | Where |
| --- | --- |
| Database `larasrouter`, role `larasrouter` | CT 130, `proxmox/opentofu/postgres.tf` (`postgres_databases`, `postgres_extra_clients`) |
| Valkey instance `larasrouter`, port 6381 | CT 132, `proxmox/opentofu/valkey.tf`, exporter 9122 |
| hEX pinholes (worker only) | `network/routeros/firewall.tf`: `forward_worker_postgres`, `forward_worker_valkey` |
| Egress for the tenant's pods | `tenant-netpol.yaml`, applied by `apply-netpol.sh` |
| Copy of the production data | `sync-db.sh check|run` |
| The two connection strings | `urls.sh database|redis`, to the clipboard only |
| A shell on the data (psql / valkey-cli) | `connect.sh db|redis [args]`: the Mac cannot reach the ports directly, the client runs inside the container through the node |

## The flip (the operator, about five minutes)

Before: `./apply-netpol.sh` done, the hEX rules applied, and a probe from the
tenant's namespace reaching 10.10.20.21:5432 and 10.10.20.23:6381 (and a probe
from another tenant's namespace not).

1. Copy the current `DATABASE_URL` and `REDIS_URL` values somewhere safe (the rollback).
2. Pause `larasrouter-api` in the Kubeletto console so nothing writes.
3. `./sync-db.sh run` (about 20 s: dump from Aiven, restore, row counts compared).
   It refuses if the app is already connected to the target.
4. `./urls.sh database | pbcopy`, paste into `DATABASE_URL`; the same with `redis`
   into `REDIS_URL`. Save, redeploy or resume the service.
5. Check: `https://api.larasrouter.com/health/ready`, a login, the wallet page.
   In Prometheus `redis_up{port="9122"}` is 1 and `pg_stat_activity` on CT 130
   shows sessions from 10.10.25.21.
6. **Rollback**: put the old two values back and redeploy. The Aiven database
   was not written to after step 2; if the app already wrote to the new one, those
   rows stay behind there.

After a week without a rollback: delete the Aiven service and the Upstash
database, remove their values from the account's notes.

## Notes

- The URLs use addresses (the DMZ does not resolve `home.arpa`), `sslmode=require`
  and `skip_verify=true`: encrypted, not verified.
- The target database is a replica until the flip: `sync-db.sh run` drops and
  restores its `public` schema every time.
- The production image is behind the repo's newest migration
  (`20261012090000_wallet_overdraft_floor`); the copy keeps the production
  version (`20260925000007`), so ship the image and migration as you would have.
