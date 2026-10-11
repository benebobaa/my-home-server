# Kubeletto migration — inventory and safety switches

What it takes to run Kubeletto (`~/Documents/benelabs/kubeletto`) on the home
K3s cluster without touching production. Plan and cuts:
[design/kubeletto-home.md](../design/kubeletto-home.md). Surveyed read-only
on 2026-10-11 at Kubeletto `92a23bd6`; paths below are in that repo.

## Never

- Run any `scripts/deploy-*.sh` or `db-migrate.sh` unchanged: they hard-code
  `SSH_HOST=kubeletto-prod` and deploy to **production**.
- Apply `infra/k8s/platform/infisical-secret-*.yaml` as-is: every Infisical
  CR reads `projectSlug: new-kubeletto-kg-ti`, `envSlug: prod` — prod
  secrets, including the prod `DATABASE_URL`.
- Point a worker-mode core at the **prod** database: leader election is a
  Postgres advisory lock, so the home outbox publisher would steal prod's
  events into the home NATS.
- Apply `registry/manifests/gc-cronjob.yaml` or `retention-cronjob.yaml`
  (`DRY_RUN=false`): both act on the shared R2 bucket from local-only
  guards. Don't run `apply-r2-lifecycle.sh`.
- Apply `monitoring/` canaries: `deploy-canary` deploys to the real
  `api.kubeletto.com` daily; the watchers post to the prod Discord.

## Safety switches for a copy (`apps/core/cmd/serverless/main.go`)

| Switch | Effect |
| --- | --- |
| `KUBELETTO_RUN_MODE=api` | no background loops at all (all 34 sit behind `IsWorker()`); deploys don't process |
| `RESEND_API_KEY` unset | no-op mail sender |
| `SUMOPOD_*` (all three) unset | checkout and plan-expiry reconciler off |
| own `REDIS_URL` | prod and the copy otherwise share deploy locks and `idempotency:` keys |
| `IDLE_APP_REAP_ENABLED`, `CRASH_LOOP_SUSPEND_ENABLED`, `EGRESS_AUTOSUSPEND_ENABLED` = `false` | reapers off (all `true` in `platform-core.yaml`) |
| `OPENOBSERVE_URL` removed, `OTEL_ENABLED=false` | samplers and exporter off |
| `DOMAINS_ISSUER=letsencrypt-http01-staging` | custom-domain reconciler can't burn LE prod rate limits |

`KUBERNETES_DRY_RUN` is read but unused — it does nothing.

In worker mode a DB copy also replays pending outbox rows and stale
queued/building builds (GitHub clone + push to R2): clean those rows or stay
in `api` mode. Creating a tenant writes a key into the prod Infisical project
(`secrets/tenant.go:232`).

## Install order (no bootstrap exists; prod was built by hand)

| # | Component | Source |
| --- | --- | --- |
| 0 | K3s `registries.yaml` on **both** nodes: `registry.kubeletto.com` → ClusterIP `10.43.229.215:5000` | `cluster-bootstrap/` |
| 1 | PriorityClass | `platform/manifests/priorityclass.yaml` |
| 2 | (cert-manager v1.17.1 — only while custom domains use HTTP-01) | `setup-cert-manager.sh` |
| 3 | Knative Serving + Kourier 1.16.0 + ~15 patches | `setup-knative.sh` |
| 4 | Traefik chart 40.2.0 / v3.7.1 (pin it; prod's script doesn't) + CF Origin certs `traefik/kubeletto-{app,com}-tls`, `sniStrict: true` | `setup-traefik.sh`, `edge/`, `setup-tls-certs.sh` |
| 5 | NATS (strip `volumeName`/bind annotations from `nats-pvc.yaml`) + auth | `nats/manifests/`, `provision-nats-auth.sh` |
| 6 | Registry (R2) + dockerhub-mirror; Service ClusterIP pinned `10.43.229.215` | `registry/manifests/` |
| 7 | Builds namespace (seccomp file copied onto the node) | `deploy-builds.sh` |
| 8 | platform-core (Service ClusterIP pinned `10.43.10.144`), migrations | `platform/manifests/`, `db-migrate.sh` |
| 9 | Admission policy (Warn) | `platform-core-admission-policy.yaml` |

Home additions: nodeSelector `node-role.kubernetes.io/control-plane: "true"`
+ the control-plane toleration on **every** platform workload (none has one;
the server taint would push them all to the worker, off the Postgres
pinhole). Widen `platform-core-internal-networkpolicy.yaml` from
`10.42.0.0/24` to `10.42.0.0/16` (build pods on the worker). Add
`100.64.0.0/10` and the home public IP to `TENANT_EGRESS_DENY_CIDRS`.

## Images

- platform-core: prod runs `kubeletto/platform-core:7554117-slim`, loaded
  straight into prod's containerd — **not in GHCR**. For a rehearsal of the
  live code: `ctr -n k8s.io images export` on prod → import on `k3s`.
- build worker: `ghcr.io/podpilott/build-worker-buildkit:3c58824`
  (`ghcr-pull` secret).
- tenant images: `registry.kubeletto.com/...@sha256` from the shared R2
  bucket; the registry token realm is hard-coded to
  `https://api.kubeletto.com/v1/registry/auth` (pulls get tokens from
  whichever core answers that name).

## Secrets (names only)

`platform-core-env` keys: `platform/expected-env-keys.txt` (drifted:
`CLOUDFLARE_ZONE_ID_APP/_COM` listed, code reads `CLOUDFLARE_ZONE_ID`).
External services behind them: Postgres (`DATABASE_URL[_DIRECT]`), Redis
(`REDIS_URL`), R2 (`R2_*`), GitHub App + OAuth (`GITHUB_*`), Cloudflare
(`CLOUDFLARE_*`, startup check only), Resend, SumoPod, NATS, `JWT_SECRET`
(**copy, never rotate**: it derives the per-user GitHub token keys),
`INTERNAL_AUTH_SECRET`, `INFISICAL_*` (tenant keys), Turnstile,
`DOMAINS_EDGE_IPS`/`DOMAINS_PROBE_ADDR` (prod IP).

Other Secrets: `registry-r2-credentials`, `registry-http-secret`,
`registry-auth-public-key` (must match `REGISTRY_AUTH_PRIVATE_KEY`),
`nats-auth`, `build-nats-auth`, `build-worker-registry-pull`, `ghcr-pull`
(platform + kubeletto-builds), `platform-core-internal-auth` and
`platform-core-registry-pull` (creation not in the repo — read from prod),
`traefik/platform-team-basic-auth`.

## Tunnel ↔ Traefik

Traefik serves Cloudflare **Origin CA** certs with `sniStrict`.
`match_sn_ito_host` in `network/cloudflare/tunnel.tf` sends the right SNI,
but cloudflared must also trust the Origin CA (`ca_pool` with the CF Origin
roots mounted into the connector) — fix when Traefik lands at home, and
verify in the same step.

## Tenant isolation

`kubeletto-base-policy` is generated per tenant namespace by core
(`runtime/knative/resources.go:376`) at deploy time and by the 10-minute
quota reconciler: ingress from the namespace, `kourier-system`,
`knative-serving`; egress DNS + `0.0.0.0/0` minus RFC1918, link-local and
`TENANT_EGRESS_DENY_CIDRS`. Prove it at home with a probe pod on the worker
(as for `cloudflared`, commit 429f435) before any tenant runs.

## Suspending a tenant on prod (no admin session needed)

The admin kill-switch is `UPDATE tenants SET suspended_at/…` + a
`tenant.suspended` row in `audit_logs`; the quota reconciler then sets the
namespace pod quota to 0 on its next pass (a pass over all tenants takes
~19 min). A quota does not stop running pods: once `pods=0` shows in the
namespace's ResourceQuota, delete the pods; Knative cannot recreate them.
Tenant namespaces are `kl-<id8>-<id8>`. Reversible with unsuspend.

## Found during rehearsal phase 1 (2026-10-11)

- **Aiven is slow: ~140 KB/s** to the prod host, measured with
  server-generated rows. Prod's app talks to its database over this link.
  The full database (1.16 GB, 941 MB of it `usage_samples`) takes over an
  hour to dump; the rehearsal copy skips `usage_samples` and
  `openobserve_read_model_exports` rows. pg_dump must run on the prod side
  (Aiven's allowlist) and be v18 (the host has 16): a throwaway
  `postgres:18-alpine` pod in ns `platform` with `envFrom` the core secret.
- **The live image is not in GHCR.** `ghcr.io/podpilott/platform-core:74cd7829`
  answers "not found"; it exists only in prod's containerd, and the
  operator's GHCR token cannot push (`denied`). Copied to VM 300 with
  `ctr images export` → chunks through the guest agent → `ctr images import`.
- **Kourier's URL in `setup-knative.sh` is dead**: release tags are
  `knative-v1.16.0`, not `kourier-v1.16.0`.
- **Traefik chart 40 reads `service.spec.type`.** Prod's `service.type:
  LoadBalancer` is ignored (LoadBalancer is the default anyway); at home
  `spec.type: ClusterIP` keeps 80/443 off the DMZ node addresses.
- **Rate limits behind the tunnel**: every request reaches Traefik from a
  cloudflared pod, so the home middlewares key on `Cf-Connecting-IP`.
- **PriorityClass first**: Knative's placement patches reference
  `kubeletto-platform-critical`; `apply.sh base` creates it before Knative.
- Cold start of a cached image through the tunnel: 2.7 s; warm: 0.3 s.
