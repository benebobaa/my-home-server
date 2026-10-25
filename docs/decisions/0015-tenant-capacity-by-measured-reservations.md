# 0015 — Tenant capacity at home: size the reservations to what pods really use, no new hardware

**Status:** accepted (2026-10-14). Decided by the operator: no hardware can be
added (budget). Settles the "growth path" left open in ADR 0011 and Kubeletto's
decision D9.

## Context

Kubeletto's tenant pods run on `k3s-worker` (VM 301 on pve3, 4 GB, 3.33 GiB
allocatable). Prod's 25 warm apps requested 7.4 GiB at the platform's default
50 % memory share while using 1.3 GiB. After a first right-sizing (15 % share,
76 Mi + a 32 Mi queue-proxy per pod) the worker held **28 warm pods by request**,
with prod already at 25 and sign-ups growing: no headroom. The options on the
table were all hardware or placement: a 16 GB SODIMM for pve3, a second worker
on pve2, or pve1 as a worker. The operator ruled hardware out; pve2 holds the
stateful guests (Postgres, monitoring) and runs no untrusted code; pve1 is on
demand (ADR 0012).

Measured on the worker (2026-10-14): a tenant app really uses 7 to 67 Mi and
its queue-proxy 9 to 12 Mi, against 76 + 32 Mi reserved, with 3.07 GB of the
VM's 3.9 GB available. The scheduler, not the RAM, was the binding limit.

## Decision

- **The reservations follow the measurement**: queue-proxy request 32 → 16 Mi
  (limit stays 128 Mi), app memory share 15 % → 12 % (61 Mi of the 512 Mi
  limit, about p75). 77 Mi per pod. Limits and billing are unchanged (billing is
  metered on the limit). Kubeletto commit `56d88deb`.
- **No new hardware, and the two placement options are dropped**: no second
  worker on pve2, no pve1 worker.
- **The ceiling is measured, not assumed**: a run with a 50 Mi tmpfs ballast per
  synthetic pod (~67 MB real, heavier than prod's ~52 Mi average) holds **40
  warm pods** by request; at that ceiling the VM uses 3.57 GB and keeps 348 MB
  available, with no MemoryPressure and no evictions. Request ceiling and real
  RAM meet, so the scheduler refuses before the kubelet has to evict.
- **Early warning, not a hardware plan**: `K8sNodeMemoryRequestsHigh` (90 %,
  about 36 warm apps) and `K8sPodUnschedulable` (ADR 0008 rules in
  `rules/k8s.yml`).

## Consequences

- Prod's 25 warm apps fit with room for about 15 more; a running build takes 512
  Mi of that.
- A pod above its request is evicted first under real memory pressure: the heavy
  apps pay, not the light ones. **The shares must never be raised back** to
  "make room": past about 3.5 GB of real use the node evicts, it does not refuse.
- If sign-ups outgrow ~36 warm apps, the levers left are software and policy:
  shorten `scale-down-delay` (60 s now) so bot traffic keeps fewer apps warm,
  cap warm free-tier apps, lower the 512 Mi build reservation. Revisit hardware
  only if those run out and the budget changes: that would be a new ADR.
- The numbers are in `docs/runbooks/kubeletto-migration.md` ("Phase 3
  rehearsal results").
