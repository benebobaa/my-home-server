# Kubeletto at home — target shape, cuts, and the move

Status: **decided 2026-10-11** — [ADR 0011](../decisions/0011-kubeletto-on-the-home-cluster.md)
for the lab side; Kubeletto's own decisions and phase plan are in its
private repo (`docs/migration/README.md`, branch `home-migration`). The
deadline stays **2026-11-05** (ADR 0004).

Kubeletto is not lifted as-is. Prod was built for one 16 GiB cloud node
with managed services around it; home is two small VMs behind a Cloudflare
Tunnel on a household IP. The move is the moment to cut what home cannot
carry or does not need.

## 1. What prod actually is (read-only, 2026-10-11)

Business figures (tenants, plans, payments, growth, abuse) are kept in
the Kubeletto repo, which is private: `docs/migration/prod-facts-2026-10-11.md`.
The ones that shape this design: almost every tenant is on the free tier,
a noticeable share of free tenants were abusive, and paid revenue is
negligible so far.

| | |
| --- | --- |
| Running tenant pods | 21 pods, 1.4 GiB, 0.25 CPU (incl. the 6 abusers) |
| Builds / deploys | 205 / 360 in 30 days (~7 builds a day) |
| Custom domains | a handful live; almost every domain row is a platform subdomain |
| Database | Aiven PG 18.6, 1.15 GB |
| Platform pods | ~4 GiB, of which OpenObserve/Vector/OTel ≈ 0.4 GiB + a 50 GiB PVC |

Home has VM 300 `k3s` (pve2, 4 vCPU / 5 GB, platform) and VM 301
`k3s-worker` (pve3, 3 GB, tenants + builds) on i3-7020U nodes, the shared
Postgres (CT 130), the lab monitoring and logs, PBS, a 50/50 Mbps DMZ cap,
no UPS, and no inbound ports.

What the repo is not: prod runs fix-wave 1 + a billing fix whose image
exists **only in prod's containerd**; the repo HEAD is a wave ahead. There
is no bootstrap, and every `deploy-*.sh` hard-codes `kubeletto-prod`. See
the [migration runbook](../runbooks/kubeletto-migration.md) for the full
inventory.

## 2. Target shape

```
Cloudflare edge ── tunnel (2 × cloudflared, node k3s) ──► Traefik ──► Kourier ──► tenant pods (k3s-worker)
                                                            │
                                                            └─► platform-core ──► Postgres CT 130 (LAN)
                                                                    │           └► Redis (in-cluster)
                                                                    └► NATS (in-cluster) ── build pods (k3s-worker)
registry (in-cluster, R2-backed) ◄── pulls from both nodes
lab Prometheus / VictoriaLogs ◄── platform metrics + logs (monitoring: block)
```

| Piece | Prod | Home |
| --- | --- | --- |
| Postgres | Aiven (internet) | CT 130 on the LAN — every request stops paying an internet round-trip per query |
| Redis | Upstash (internet) | in-cluster, no persistence (cache, locks, rate limits only) |
| Secrets | Infisical operator, prod env | SOPS in this repo → k8s Secrets (app standard §4). Core still calls the Infisical **API** for tenant keys (code dependency, stays) |
| Ingress | public IP, Traefik + Kourier | tunnel → Traefik + Kourier (unchanged) |
| Edge TLS | CF Origin certs, `sniStrict` | same certs; the tunnel trusts the Origin CA (`ca_pool`) |
| Observability | OpenObserve, Vector, OTel, kube-state-metrics, node-exporter, canaries | **removed** → lab standard (ADR 0008) |
| Registry | R2, shared bucket | same bucket (no image moves); GC and retention **never** run at home |
| Placement | one node | platform on `k3s` (nodeSelector + toleration on every platform workload); tenants + builds on the worker by the taint |

## 3. Cut (recommended)

| Cut | Why | Replaced by |
| --- | --- | --- |
| OpenObserve, Vector, OTel (3), nats-openobserve bridge, kube-state-metrics, node-exporter, nats-exporter | ~0.4 GiB + 50 GiB disk + CPU; a second observability stack beside the lab's | lab Prometheus scrapes core/Knative/NATS; logs to VictoriaLogs |
| Usage-based metering samplers (HTTP, bandwidth, log-bytes) and the read-model exporter | Built on OpenObserve; meters revenue the platform does not have yet | plan-based limits only; usage tables stay for later |
| Egress auto-suspend (depends on the bandwidth sampler) | Dies with the sampler | **per-pod bandwidth cap** (`kubernetes.io/egress-bandwidth`, K3s ships the CNI bandwidth plugin) — a hard cap instead of after-the-fact metering |
| Tenant metrics charts (MetricsQuerier) | OpenObserve-backed | request count + status from Kourier metrics later, if missed |
| Tenant log history | OpenObserve-backed | live logs from the Kubernetes API (recent lines); build logs saved to Postgres/R2 at build end |
| `deploy-canary`, `edge-canary`, `cron-failure-watcher` | Duplicate the lab's blackbox probes and Alertmanager | `monitoring:` block probes + Telegram |
| cert-manager + HTTP-01 + `domains.kubeletto.app` (DNS-only to the server IP) | Cannot work behind a tunnel; only a handful of live custom domains | **Cloudflare for SaaS** custom hostnames (first 100 free), tunnel as fallback origin |
| Infisical operator | Syncs prod secrets into any cluster that has its credentials | SOPS |
| Upstash, Aiven | Monthly cost + internet latency | in-cluster Redis, CT 130 |

Kept: Knative + Kourier, Traefik, NATS JetStream, the registry on R2 +
dockerhub-mirror (saves home bandwidth on builds), BuildKit builds, the
DB-based reapers (idle, crash-loop), the admin kill-switch, SumoPod, Resend,
the console on Cloudflare Pages.

## 4. Fit the home (change, don't cut)

- **Free tier on a household IP.** a noticeable share of free tenants were abusive; at home
  their traffic leaves from the family's IP. Free tier becomes: scale to
  zero only (no min-scale, max 1 instance), egress TCP 80/443 + DNS only,
  per-pod egress cap (~2 Mbit), the existing egress deny for RFC1918 plus
  `100.64.0.0/10` and the home public IP, and a sign-up gate (GitHub
  account age, or approval).
- **Builds.** One at a time on the worker (3 GB). pve1 can take builds
  later when it is on.
- **Capacity.** Worker: ~1.1 GiB tenants (without the abusers) + 1 GiB for
  one build fits 3 GB. Server: K3s ~1.3 GB + platform ~1.6 GiB requests
  fits 5 GB without OpenObserve.
- **Cold starts.** Tenant images come from R2 over the home downlink once,
  then stay in the worker's containerd; the dockerhub-mirror stays.

## 5. Phases

| Phase | When | What | Done means |
| --- | --- | --- | --- |
| 0 | now | Abusers stopped on prod; this proposal decided | 6 namespaces at 0 pods; §6 answered |
| 1 Rehearse infra (**done Oct 11**, except a real console login: the console is wired to api.kubeletto.com; a DB-backed login request was tested instead) | Oct 12–16 | DB copy → CT 130; **the live prod image** in `KUBELETTO_RUN_MODE=api` (no background loops), Resend/SumoPod unset, in-cluster Redis, no GC/retention/canaries; test hostname `home-api.kubeletto.com` via the tunnel | console logs in against home API; a tenant app answers through the tunnel on a test hostname |
| 2 Realign code | Oct 14–25 (Kubeletto repo, its sprint SOP) | §3 cuts, §4 free-tier limits, placement config, CF for SaaS, in-cluster Redis | repo tests pass; image in GHCR |
| 3 Full rehearsal | Oct 26–29 | realigned image in worker mode on a fresh DB copy; cold reboot of both nodes; PBS + dump restore | deploy from GitHub → live through tunnel; survives reboot |
| 4 Cutover | Oct 30–Nov 1 | freeze prod writes, final dump/restore (~1 GB, minutes), Infisical/R2/GitHub secrets copied (JWT_SECRET **copied, not rotated**), DNS records → tunnel | prod names served from home; old server kept as rollback until Nov 5 |

## 6. Decisions (taken 2026-10-11 by Kubeletto's owner)

1. **Free tier**: keep it open, gate it, or close new free sign-ups?
   **Decided:** gated (GitHub account at least 30 days old) + the §4 limits.
2. **Custom domains**: CF for SaaS (code change before cutover), or switch
   the feature off and mail the few tenants using it? **Decided:** CF for SaaS; off as
   the fallback if it is not ready by Oct 28.
3. **Usage metering and tenant metrics**: drop now, rebuild on Prometheus if
   paying customers appear? **Decided:** drop; tenant logs go to an
   in-cluster VictoriaLogs instead of OpenObserve.
4. **Code version at cutover**: **decided:** fix-wave 1 + 2 (never deployed
   to prod) plus the home changes, rehearsed in phase 3; prod stays frozen.
   Phase 1 uses the live image only to prove the infrastructure.

Risks carried: the home registry reads and writes prod's shared R2 bucket
(fine for pulls; GC/retention must never run at home); no UPS yet (a power
cut takes the platform down until power returns); one household uplink.
