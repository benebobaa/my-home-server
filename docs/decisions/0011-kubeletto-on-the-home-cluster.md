# 0011 — Kubeletto runs on the home K3s cluster, cut down for a household IP

**Status:** accepted (2026-10-11). Decided by Claude as Kubeletto's owner,
by the operator's delegation the same day.

## Context

ADR 0004 chose Cloudflare Tunnel for public ingress and moving Kubeletto
home before the rented server ends (2026-11-05). The proposal in
[design/kubeletto-home.md](../design/kubeletto-home.md) laid out how; rehearsal
phase 1 then ran prod's live code at home on a copy of the database
(2026-10-11). Kubeletto's own decisions (code version, free-tier rules,
logs, custom domains) are recorded in its private repo,
`docs/migration/README.md` on branch `home-migration`. This ADR records what
they mean for the lab.

Facts that drove it: the K3s VMs are small (5 GB platform, 3 GB tenants);
tenant traffic leaves from the family's public IP; a noticeable share of
free tenants were abusive; OpenObserve alone reserved 2 GiB on prod; the
rented server's managed Postgres answers at ~140 KB/s per connection.

## Decision

- **Kubeletto is a lab app on K3s.** Platform on VM 300 `k3s` (pve2,
  tainted, the only address through the Postgres pinhole), tenants and
  builds on VM 301 `k3s-worker` (pve3). Its database is `kubeletto` in the
  shared Postgres (ADR 0010); Redis runs in-cluster without persistence;
  the registry stays on R2.
- **Public traffic only through the tunnel**: Traefik and Kourier are
  ClusterIP and accept traffic only along cloudflared → Traefik → Kourier
  (NetworkPolicies). No port forwards (ADR 0004 unchanged).
- **The free tier is boxed for a household IP**: egress 80/443 + DNS, a
  per-pod bandwidth cap, and every tenant denied RFC1918, `100.64.0.0/10`
  and the home public IP. The hEX's DMZ rules stay the outer wall.
- **One observability stack.** OpenObserve, Vector and OTel do not come
  home. Platform metrics and alerts go through the lab's Prometheus and
  Alertmanager (a MGMT → DMZ scrape rule on the hEX, added with the
  scrape targets); tenant logs go to a small VictoriaLogs inside the DMZ
  cluster (the DMZ never pushes into MGMT, ADR 0008).
- **Copies of production data are operator-only.** Any rehearsal name that
  serves prod data sits behind an allowlist of the operator's IPv6 /64,
  created at apply time (this repo is public); never IPv4, which tenants
  share.
- **Kubeletto's business data stays out of this repo.**

## Consequences

- The lab carries a public, multi-tenant service: K3s, the tunnel and
  CT 130 become `critical` in their `monitoring:` blocks at cutover, and a
  power cut now takes customers offline. The operator moved the nodes on
  2026-10-11 (both rebooted cleanly afterwards); a UPS for the hEX,
  switch and ONT is recommended before cutover — the nodes are laptops.
- The rehearsal stack in `services/kubeletto/` is generated from prod's
  live objects; at phase 2 it is replaced by manifests from Kubeletto's
  `home-migration` branch.
- pve1, when built, joins as a second worker for builds; that changes its
  "on-demand only" rule and gets its own ADR.
