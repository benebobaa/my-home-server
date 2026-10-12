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
| 2 | (cert-manager v1.17.1 — prod only: home custom domains use Cloudflare for SaaS) | `setup-cert-manager.sh` |
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

## Custom domains (Cloudflare for SaaS, decision D4)

At home there is no public IP for customers' domains to point at, so
Cloudflare terminates them: each domain is a *custom hostname* on the
`kubeletto.app` zone, Cloudflare issues its certificate, and sends the
request to the zone's fallback origin `saas-origin.kubeletto.app` → the
tunnel. The tunnel's catch-all rule hands any other Host to Traefik with the
fixed SNI `saas-origin.kubeletto.app` (covered by the `*.kubeletto.app`
Origin cert); Traefik routes on the Host header to the per-domain
IngressRoute → Kourier → the tenant's DomainMapping. No cert-manager at home.

- Zone side: `network/cloudflare/saas.tf` (+ the catch-all in `tunnel.tf`).
- Per-domain custom hostnames: Kubeletto core, with its own token
  `CLOUDFLARE_SAAS_TOKEN` (`services/kubeletto/secrets.sops.env`: SSL and
  Certificates edit on `kubeletto.app`, nothing else). Prod core's
  `CLOUDFLARE_API_TOKEN` has no access to `kubeletto.app`.
- Proven by hand 2026-10-12 with `saas-test.kubeletto.com` (CNAME, DNS-only,
  → `saas-origin.kubeletto.app`): custom hostname and certificate active
  within a minute, 200 from the canary through Cloudflare → tunnel → Traefik
  (Host ≠ SNI is accepted) → Kourier, certificate issued by Cloudflare for
  the exact name.
- Customer instructions stay "CNAME to `domains.kubeletto.app`". Apex
  domains work only where the customer's DNS flattens a CNAME/ALIAS: A
  records to Cloudflare IPs need Apex Proxying (Enterprise).
- Cost: 100 custom hostnames free, then $0.10/month each. Kubeletto counts
  verified domains only: free-plan tenants may fill the zone to 90
  (`DOMAINS_PLATFORM_CAP`), paid tenants to 300
  (`DOMAINS_PLATFORM_PAID_CAP`), checked at the API and, against the zone's
  real count, before every create.
- Core config (Kubeletto repo `infra/k8s/home/platform-core-patch.yaml`):
  `DOMAINS_EDGE_PROVIDER=cloudflare`, the two caps, and
  `DOMAINS_RECONCILE_TENANTS` = the internal canary tenant only, so the DB
  copy's real customer domains are never registered or torn down. The
  token reaches core through `secrets.sh` (`platform-core-env`).
- Proven through Kubeletto 2026-10-12 (core `7927a4bf`): a verified
  `saas-test.kubeletto.com` row for the canary went ACTIVE by itself in ~3
  min (custom hostname created, certificate issued, probe through the
  edge), served the alias 301, then 200 from the app after "set primary"
  via the API; API delete → `removed`, 0 custom hostnames at Cloudflare and
  no route, middleware, mapping or claim left. Real customer rows untouched
  since the new core started. (kubeletto.com subdomains are rejected by the
  API's validator, so that row was inserted directly in the copy.)

**At cutover** (customer-facing: operator's yes first; tell the custom-domain
owners beforehand: each domain has a short HTTPS gap, ~1–3 min measured,
between the flip and its Cloudflare certificate):
1. Remove `DOMAINS_RECONCILE_TENANTS` from the core patch and apply. The
   reconciler creates the existing domains' custom hostnames while prod
   still serves them; they wait `pending` (free, no traffic change).
2. Flip `domains.kubeletto.app` in `records.tf` from the DNS-only A record
   to a proxied CNAME → `saas-origin.kubeletto.app`. HTTP validation then
   completes and each domain goes ACTIVE; watch the rows and
   `curl https://<domain>/`.

In this order validation starts the moment traffic reaches Cloudflare; the
reverse adds the record TTL, a reconcile interval and the create to the gap.
The first Cloudflare-mode pass emits one `domain.degraded` event per
already-active domain (certificate back to issuing): it only lands in the
NATS `DOMAINS` stream, nothing turns it into a notification or mail. The
pre-cutover copy carries `certificate_apply_failed` on those rows from the
cert-manager attempt before the switch; the final DB copy replaces them.

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
Tenant namespaces are `kl-<id8>-<id8>`. **Not fully reversible**: with the
pods gone the services sit in `RevisionMissing`, and after 30 min the
crash-loop suspender deletes them, so unsuspend restores the account but
the tenant must redeploy (incident 2026-10-11-kubeletto-prod-ksvc-deletions).

Prod's node runs at its memory-request limit: never start an operational
pod there with resource requests (`"resources":{}`), or tenant cold starts
fail and the same suspender deletes their services.

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
- **Prod addresses inside `platform-core-env`**: `NATS_URL` is prod's NATS
  ClusterIP (`10.43.196.254`; secrets.sh rewrites it to DNS);
  `PLATFORM_API_URL` and `SESSION_COOKIE_DOMAIN` carry the rented server's
  public IP — change both at cutover. `REGISTRY_URL` is the pinned
  `10.43.229.215`, kept.
- **Not every loop is worker-only**: in `api` mode core still starts the
  webhook-delivery reconciler (replays `pending` GitHub deliveries; the copy
  had none) and the installation-drift reconciler (GitHub reads, DB writes).
  Check for pending deliveries before starting a copy.
- **Postgres served localhost only after an unclean pve2 boot** (bind race,
  fixed in `services/postgres/setup.sh`); the exporter uses the socket, so
  nothing alerted.
- Measured through the tunnel from the LAN: `/readyz` 0.29 s at home vs
  0.89 s on prod; a failed login (one user lookup) 2.2 s vs 5.1 s.

## Found during phase 2 (2026-10-11)

- **The legacy GHCR packages are not linked to the repo**: the workflow
  token gets `permission_denied: read_package` on `platform-core` /
  `build-worker-buildkit`. Home images are new packages created by the
  workflow: `ghcr.io/podpilott/kubeletto-core`, `kubeletto-build-worker`.
- **Cross-tenant log injection in Vector (prod too, fixed and applied
  2026-10-11)**: the normalize transform merged a log line's JSON before
  reading the tenant from pod labels. Fixed in three rounds after security
  reviews: restore collector metadata after the merge; drop identity keys in
  any letter case (core decodes with Go, case-insensitive); compare names as
  log stores normalize/flatten them. `infra/k8s/home/vector-tests.toml`
  proves it (fails on the old config).
- **Build pods lacked the tenant egress denies** (CGNAT, link-local, the
  home IP): the home overlay adds them.
- The prod dump in the Kubeletto repo has no Vector ServiceAccount/RBAC, and
  two build Role/RoleBinding files duplicate each other.
- **Knative cannot jump 1.16 → 1.23 in place** (one minor per upgrade): the
  home cluster had only rehearsal objects, so 1.16 was uninstalled and 1.23
  installed fresh. Prod's cutover does not upgrade Knative in place either:
  the home cluster is built new.
- wave 1+2 needs `DOMAINS_EDGE_IPS`/`DOMAINS_PROBE_ADDR` (startup) and
  migrations 097–099 (schema gate); `services/kubeletto/migrate.sh` runs
  goose inside CT 130 against the home copy.
- `PLATFORM_API_URL` and `SESSION_COOKIE_DOMAIN` are not read by any code.
- **A fresh build pod is refused for its first seconds** (2026-10-12): the
  first GitHub-built deploy failed at clone with "connection refused" from
  the build pod to core :9090. K3s's network policy controller (kube-router)
  adds a new pod's IP to the allow sets ~2–4 s after start and REJECTs
  until then (a probe pod with the build labels: refused at +0/+2 s, through
  from +4 s). Fixed in the worker (Kubeletto `8737ce6d`: the token fetch
  retries transient errors for ~23 s). Any new in-cluster client that
  talks first thing after start needs the same tolerance.
- **GitHub-built deploy proven** (2026-10-12, core `7927a4bf`, worker
  `8737ce6d`): repo linked through the operator tenant's GitHub App
  installation (`/v1/projects/:id/source`), `/source/deploy` → token
  minted on the 3rd attempt → clone → buildpacks build → push to the home
  registry (R2) → Knative service active in ~4 min, 200 from the app
  through Traefik. Test project deleted through the API afterwards (service
  gone). GitHub webhooks still go to prod until cutover, so push-triggered
  deploys are a cutover check, not a rehearsal one.
- **Tenant capacity** (2026-10-12): prod's 25 warm tenant apps (47
  services, none pinned warm) requested 7.4 GiB at the default 50% memory
  share but used 1.3 GiB (p50 35 MiB, p90 81 MiB, max 379 MiB of 512 MiB
  limits); the worker allocated 2.4 GiB. Fixed for today's load: worker VM
  301 3 → 4 GB (allocatable 3.33 GiB; pve3 keeps ~1.5 GB with PBS
  resident) and Kubeletto's home request shares (`e8f37aee`: memory 15%,
  CPU 10%, builds 250m/512Mi, queue-proxy 10m/32Mi; limits and billing
  unchanged). Proven: a warm app requested 76+32 Mi / 50+10m and a build
  (250m/512Mi) scheduled beside it. Today's mix plus one build is ~3.2 of
  3.33 GiB: it fits, with no growth headroom. Both nodes' memory is in
  Prometheus (node_exporter, Kubeletto `infra/k8s/home/node-exporter.yaml`;
  job `service_dmz`) and `HostMemoryLow` covers them. Growth path is a
  pending decision (Kubeletto docs/migration D9), but not pve1 (on demand,
  ADR 0012): a 16 GB SODIMM for pve3, or a second worker on pve2 once
  CT 110 is gone.
