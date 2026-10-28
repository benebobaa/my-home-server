# 0022 — larasrouter, a Kubeletto tenant app, uses the shared Postgres and Valkey

**Status:** accepted in principle (2026-10-28), **blocked**: the pinholes were applied and removed again the same hour (see Follow-up). Asked for by the operator:
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
- **What was meant to keep other tenants out is the tenant's own egress policy.**
  Every tenant namespace carries Kubeletto's base NetworkPolicy (believed to
  deny private ranges; it does not, see Follow-up). larasrouter's namespace gets one additional policy,
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

## Follow-up (2026-10-28): a probe that looked like a failure, and what it showed

The two pinholes were applied at 15:35. A probe pod in another tenant's
namespace (the canary) reached 5432 and 6381 at 15:37, so the rules were
removed at once, believing the tenants' base NetworkPolicy did not deny private
ranges. **That reading was wrong.** The base policy does deny 10/8, 172.16/12,
192.168/16, link-local and CGNAT (checked on the live object), and a probe that
waits 25 s before connecting is blocked from every private target (the
server's API port 10.10.25.20:6443, the in-cluster API 10.43.0.1:443) and reaches
only the public internet. The first probe ran in the first second of the
pod's life: **kube-router programs a new pod's firewall a moment after the pod
starts, and until then the pod is unrestricted.**

What this means for the rules:

- In steady state only larasrouter's namespace (through `larasrouter-data`)
  reaches Postgres and its Valkey; any other tenant is blocked, as designed.
- **Residual:** a new tenant pod has a window of a few seconds, at every start,
  in which it can open a connection to anything its node can route to, the two
  pinholed ports included (and, today, the kube-apiserver and node ports).
  A connection still needs the credentials: `pg_hba` admits only the
  `larasrouter` role for its database over TLS (scram, a 32-character random
  password), Valkey requires its password. The operator decides whether that
  is acceptable; the alternative is a data store inside the DMZ.
- Separately, the same window is a pre-existing property of the platform, not
  introduced here.
