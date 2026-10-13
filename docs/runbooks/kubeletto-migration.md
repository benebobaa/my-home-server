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

## Cutover: database and state

Rehearsed end to end on 2026-10-14 with `services/kubeletto/dbcopy.sh`
(and `migrate.sh` with `KUBELETTO_DB`). Nothing in it touches the live home
database until the last step, and the copy is built beside it.

| # | Step | Measured | Notes |
| --- | --- | --- | --- |
| 1 | `dbcopy.sh dump` | **1 min to 12 min** | One requests-free pod on prod runs `pg_dump -Fd -j4`, `usage_samples` rows left out. The Aiven link is uneven (~140 KB/s to 1 MB/s) and `github_webhook_deliveries` (JSON payloads, the largest table) is one `COPY` no `-j` can split: budget 15 min. The pod is deleted when the dump is off the node |
| 2 | pull + push to CT 130 | 10 s + 20 s | the dump is tens of MB; relayed through the Mac |
| 3 | `dbcopy.sh restore kubeletto_next` | 11 s | into a NEW database owned by the app role; refuses to target `kubeletto` |
| 4 | `KUBELETTO_DB=kubeletto_next ./migrate.sh up` | ms (goose 097→100) | scratch copies are migrated over the local socket as `postgres` with `role=kubeletto`, because pg_hba admits the app role to its own database only. Schema diffed against the live copy: identical |
| 5 | `dbcopy.sh check kubeletto_next` | instant | refuses (exit 1) if a worker-mode core would replay anything: pending or leased outbox events, builds not terminal, pending webhook deliveries. Proven by planting a pending row |
| 6 | scale the home core to 0, `dbcopy.sh swap kubeletto_next --yes` | instant | renames `kubeletto` → `kubeletto_prev`, `kubeletto_next` → `kubeletto`; refuses while anything is connected. Proven on scratch databases |
| 7 | start the core, `/readyz`, one login, one deploy | | rollback of this step alone: stop the core, rename back |
| 7b | `restore.sh run`, then `restore.sh run --apply` | ~5 s per service (paced) | **no tenant app exists on a fresh cluster and nothing recreates one from the database**: this redeploys each service that ran on prod (stored image, no rebuild). The list is captured at step 0 (`restore.sh list`, while prod is frozen, before anything is deleted there). Suspended tenants are skipped; the first run is a dry run. Proven 2026-10-14 on the operator's and the canary's tenants (4 services, Ready in under a minute, answering through Kourier) |
| 8 | `dbcopy.sh clean` | instant | deletes the Mac's copy of the production dump (hashes, tokens, encrypted env vars; kept 0700 under `~/.cache/kubeletto-dump`). The staging in CT 130 (`/opt/kdump`, `/opt/kmig`) and on pve2 removes itself |

Total with prod frozen: about 3 min when the link is fast, 15 min when slow.

Order around it (the operator's yes for 1 and 7, both customer-facing; also for
the first full `restore.sh run --apply`, which starts every active tenant's
code at home, with no traffic yet). Staging never uses
a predictable path in a world-writable directory (root-owned `/opt/...` in the
CT, `mktemp` on pve2): what lands there runs as root or `postgres`. The dump
pod runs as uid 70, non-root, no capabilities:
0. `restore.sh list` first: it reads prod's Knative services (read-only) into
   a private file; scaling prod's core to 0 does not delete them.
1. Let in-flight builds on prod finish, then scale prod's core to 0 (the
   downtime starts). Prod's outbox is normally empty within seconds; if
   `check` still finds pending rows, they are events prod never published:
   decide, do not delete.
2. Steps 1 to 6 above. 3. DNS to the tunnel, then the custom-domain steps
   under "At cutover" above.

**Open before cutover** (none blocks the rehearsal; each blocks the day):
- **Secrets** (done 2026-10-14, one decision left for the operator): prod
  disappears on 2026-11-05 and the home cluster's etcd would hold the only
  copy of `JWT_SECRET`, the GitHub App, R2 and registry keys, the origin TLS
  certs. `./secrets.sh snapshot` reads prod once (read-only) and writes the
  keys home keeps to `secrets.prod-snapshot.sops.json` (SOPS, age), then
  re-reads prod and compares value by value (64 values, 0 differ). Aiven,
  Upstash, prod's NATS and OpenObserve values are not stored: home replaces
  or drops them. `./secrets.sh verify` compares the cluster to the snapshot
  (60 values, 0 differ); `./secrets.sh --from-snapshot` applies without
  prod, proven to give byte-identical Secrets to a prod-sourced apply.
  **`--live` is the cutover switch**: the rehearsal drops `RESEND_API_KEY`
  and `SUMOPOD_*` (mail, checkout); the cutover must run
  `./secrets.sh --from-snapshot --live` or the home platform sends no mail
  and takes no payments. The snapshot is **gitignored on purpose**: it is the
  ciphertext of every shared prod secret and this repo is public, and
  `JWT_SECRET` can never be rotated. Keeping it local (and in the home
  cluster) is the default; committing it is the operator's call, with that
  trade-off (a copy off the Mac versus ciphertext of the crown jewels in a
  public history, protected by one age key).
  Not a secret but found on the way: `TENANT_EGRESS_DENY_CIDRS` carries the
  home's public IPv4, which sits behind Biznet's CGNAT and changes (the
  running core had a stale one after two days). It is defense in depth only:
  nothing can come in through it, and the hard control is the hEX's DMZ
  drops. To refresh: re-run `secrets.sh` and restart `platform-core`.
- **Home test state** (cleared by hand before the new core starts; the
  swap replaces rows, not the cluster): the canary's rehearsal Knative
  services, and the `dom-*` IngressRoutes and Middlewares in namespace
  `traefik` that the rehearsal's custom-domain rows created (the canary tenant
  has 5 such rows; a gated reconciler only ever touched it). Tenant namespaces
  `kl-<id8>-<id8>` are NOT to be deleted: one per tenant id, and the final copy
  keeps the ids; their `DomainMapping`s sit in `ResolveFailed` until a service
  exists, harmless. Check Cloudflare for custom hostnames the rehearsal left
  (the rehearsal's test domain was deleted through the API; expected 0).
- **Infisical** (read from the code 2026-10-14): not a server dependency,
  so nothing retires it. It is a hard runtime dependency: each tenant's
  env-var encryption key lives only there (the database holds a key reference
  and ciphertext), so the platform needs the same `INFISICAL_*` credentials at
  home (the snapshot keeps them) and the project must outlive the cutover. If
  the key were lost, every stored env var of that tenant is unreadable. Keep
  the project, and consider an export of its tenant keys into the operator's
  own backup (not done: it would copy every tenant's key). During the
  rehearsal the home core writes keys for tenants it creates into the same
  project: harmless junk.
- **GitHub webhook** (verified 2026-10-14): prod's access log shows every
  recent delivery (144, all 202) arriving at host `api.kubeletto.com`, so the
  DNS flip carries GitHub's webhooks with no change in GitHub.
- **Rollback and its data window**: DNS back to the rented server resumes
  prod on Aiven (kept 7 days after cutover, D6). Anything written at home
  after the cutover (sign-ups, deploys, usage) is lost. Accepted: cost over
  production-readiness.
- **Operator's yes, listed**: freezing prod, DNS to the tunnel, the
  `domains.kubeletto.app` flip, dropping `DOMAINS_RECONCILE_TENANTS`, the
  webhook URL if needed, deleting Aiven and Upstash after the 7 days.

## Phase 3 rehearsal results (2026-10-14)

Proofs run ahead of the 10-25 window, on the home cluster with the
rehearsal data. Each is repeatable with the commands in the section it names.

| Proof | Result |
| --- | --- |
| Cold reboot, **pve3** (worker VM, PBS, `admin-gw`) | back in ~80 s; all 3 guests started by themselves; quorate throughout (3 votes); worker rejoined; every pod Running, all restored apps Ready |
| Cold reboot, **pve2** (K3s server VM, Postgres, monitoring, logs, `admin-gw2`) | SSH in ~2.5 min; all 5 always-on guests up in 3 min; **Postgres serves on its LAN address** (the 10-11 bind race stays fixed); both K3s nodes Ready in 3 min and all pods Running 20 s later; cloudflared 4 tunnel connections; Prometheus 43 targets up, every rule healthy |
| PBS restore of **CT 130** (the Kubeletto database) | tonight's snapshot restored into a throwaway CT in 29 s (network stripped before first start: the restored config would reuse the real Postgres IP); Postgres ran crash recovery on the live-taken snapshot and served the data (migration 100, tenants, services, encrypted env vars all present); throwaway destroyed, the real CT untouched. VM 300 (K3s server, holds etcd) and CT 130 are in the nightly job; VM 301 is a stub by design (`backup=false`) |
| Worker capacity (D9) | 40 warm tenant-shaped services (76 Mi + 32 Mi queue-proxy requests, 50 m + 10 m CPU, minScale 1) requested on a 3.33 GiB worker: **28 pods fit, 12 stay Pending at 98 % of allocatable memory requests**. 25 warm apps plus the platform and the restored apps sit at 89 %, i.e. room for about 2 more |
| Scheduler alerts | `K8sPodUnschedulable` fired 5 min after the first Pending pod ("12 pod(s) unschedulable"), `K8sNodeMemoryRequestsHigh` fired at 98.5 % after its 15 min, both reached Alertmanager; all resolved ~2 min after the load was deleted. `K8sNodeMemoryPressure` is not provoked (it needs real memory exhaustion) and rests on the unit test |
| Tenant restore (`restore.sh`) | see "Cutover: database and state", step 7b: 4 services restored and answering |

What the capacity number means: prod's 25 warm apps fit, with about two pods
of headroom: one more busy day of sign-ups and the 29th warm app is
unschedulable. The growth path (16 GB SODIMM for pve3, or a second worker on
pve2 once CT 110 is gone) is still the operator's call; the alerts above are
what will say so in time.

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
