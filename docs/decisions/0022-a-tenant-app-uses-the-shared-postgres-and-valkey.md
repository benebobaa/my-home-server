# 0022 — larasrouter, a Kubeletto tenant app, uses the shared Postgres and Valkey

**Status:** accepted (2026-10-28), for this one app. Asked for by the operator:
larasrouter (its own project, running as a tenant on Kubeletto under its own
account) should use the lab's Postgres and Valkey instead of its own Aiven and
Upstash services. Amends the DMZ rule of [ADR 0004](0004-public-ingress-cloudflare-tunnel.md)
and the app standard ([ADR 0010](0010-shared-postgres-and-app-standard.md),
[0016](0016-shared-nats-and-valkey.md)) for a tenant that runs in the DMZ.

## Context

larasrouter's API ran with an Aiven Postgres (11 MB, 23 tables, PostgreSQL 18.6,
no extension) and an Upstash Redis whose free monthly request limit (500,000) was
already exhausted, so its session cache, rate limits and reset cooldowns were
failing open. Its data is small and its Redis use is ephemeral. The
obstacle is not capacity but reachability: tenant pods run on the K3s worker in
the DMZ, and the DMZ has pinholes to the lab only from the K3s *server* VM
(Kubeletto's own core), never from the worker, because tenant and build code
runs there.

## Decision

- A database and role `larasrouter` on the shared Postgres (`postgres_databases`),
  and a Valkey instance `larasrouter` (port 6381, 64 MB, `volatile-lru`), both
  generated and wired by OpenTofu like any app.
- **Two hEX pinholes from the worker**: `10.10.25.21` to `10.10.20.21:5432` and to
  `10.10.20.23:6381`, nothing else (`forward_worker_postgres`,
  `forward_worker_valkey`). At the data end: a `pg_hba` hostssl line for this
  database and role from `10.10.25.21/32` only, and the Valkey password.
- **What keeps other tenants out is the tenant's own egress policy.** Every
  tenant namespace carries Kubeletto's base NetworkPolicy (private ranges
  denied). larasrouter's namespace gets one additional policy,
  `larasrouter-data` (`services/larasrouter/tenant-netpol.yaml`), allowing
  egress to exactly those two addresses and ports. Core reconciles only
  `kubeletto-base-policy`, so the extra object stays.
- The connection strings use `sslmode=require` and `?skip_verify=true`
  (encrypted, server not verified): larasrouter's Redis client takes no CA
  bundle. A `REDIS_TLS_CA` option in its code would pin the certificate
  (ADR 0017).
- The operator flips `DATABASE_URL` and `REDIS_URL` in the Kubeletto console;
  `services/larasrouter/` holds the copy (`sync-db.sh`), the strings
  (`urls.sh`, clipboard only) and the runbook.

## Consequences

- **The worker can now reach two lab services.** The isolation of every other
  tenant rests on the base NetworkPolicy (kube-router) and, behind it, on
  `pg_hba` (a different database or role is refused) and the Valkey password
  (the instance requires it). A node-level compromise of the worker would see
  both ports. The operator accepted this for this app. A second tenant app that
  wants the same gets its own ADR, not a copy of this one.
- Postgres and Valkey now serve a tenant: the database is in the nightly dump
  and the PBS backup of CT 130; Valkey keeps nothing (no persistence).
- Aiven and Upstash can be deleted a week after the flip.
