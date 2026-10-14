# Kubeletto cutover: from the rented server to the home cluster

The day-of checklist, in order. The inventory, the safety switches and the
reasons are in [kubeletto-migration.md](kubeletto-migration.md); the plan and
decisions are [ADR 0011](../decisions/0011-kubeletto-on-the-home-cluster.md)
and Kubeletto's `docs/migration/README.md`. Window: **2026-10-30 to 11-01**.
The rented server is decommissioned on **2026-11-05** and is the rollback until then.

**What stays up while you work.** Tenant apps are served by prod's own Traefik
and Knative, not by its core: scaling prod's core to 0 takes the API, console
and deploys down, but customers' apps keep answering until the DNS flip
(step 9). Their outage is the flip itself, seconds on proxied records.

Run everything from `services/kubeletto/` on the operator Mac. The dump lives
in `~/.cache/kubeletto-dump` (0700, wiped by every `dump`; `./dbcopy.sh clean`
after step 4); prod's SSH address goes in `KUBELETTO_PROD_SSH` (the
`kubeletto-prod` alias points at a Tailscale address that timed out on
2026-10-14).

## Before the day (no customer impact)

1. **Worker capacity (D9) is settled without hardware** (budget): the request
   shares follow the measurement and the 4 GB worker holds **40 warm tenant
   pods** (runbook "Phase 3 rehearsal results"); prod runs 25. Re-check the
   number of warm apps on prod the day before (`kubectl get ksvc -A`,
   pods Running): above ~36, shorten `scale-down-delay` first.
2. `make check`; both Tofu stacks and Ansible `--check`: **No changes**
   (`proxmox/opentofu` also wants to start CT 110 while it is stopped on
   purpose: plan with `-target` or delete CT 110 first).
3. `./secrets.sh snapshot` (ends with `0 differ`), then `./secrets.sh verify`.
4. A fresh backup of VM 300 and CT 130 exists (PBS, nightly 02:30); take a
   manual one if the day's is older than a day.
5. Phase 3 rehearsal passed on a fresh copy (dump → swap → restore → deploy
   → reboot), including **the operator's yes** for the first full
   `restore.sh run --apply`.
6. **Operator**: tell the custom-domain owners and the tenants about the
   window (API/console down for the database step, ~3 to 15 min; each custom
   domain has a short HTTPS gap, ~1 to 3 min, after the flip).
7. Both edits of the day are prepared as branches, already committed and
   checked (nothing applied):
   - Kubeletto worktree, branch `cutover-live`: `DOMAINS_RECONCILE_TENANTS`
     removed from the core patch (the overlay renders without it).
   - homeserver, branch `cutover-flip`: the three records as they are after
     the flip; applied only through `network/cloudflare/flip.sh` (below).

## The day

| # | Step | Verify | Needs the operator's yes |
| --- | --- | --- | --- |
| 0 | `./restore.sh list` (prod's tenant Knative services and the digest each runs, read-only; saved in `~/.cache/kubeletto-restore/`, apart from the dump's directory, which step 2 wipes) | "listed N tenant services" | |
| 0b | `./images.sh` (pre-pull every external tenant image on the worker; prod's resolved digests come from the list) | `unavailable` lists only images that are dead on prod too or run there from a snapshot (their owners redeploy afterwards) | |
| 1 | Prod: let in-flight builds finish, then `ssh kubeletto-prod kubectl -n platform scale deploy platform-core --replicas=0` | prod `/readyz` fails; tenant apps still answer | **yes** (API and deploys down) |
| 2 | `./dbcopy.sh dump && ./dbcopy.sh restore kubeletto_next && KUBELETTO_DB=kubeletto_next ./migrate.sh up && ./dbcopy.sh check kubeletto_next` | `goose version 100`, `clean` | |
| 3 | Home: scale `platform-core` to 0; delete all `dom-*` IngressRoutes and Middlewares in ns `traefik` | `kubectl -n traefik get ingressroute` lists none starting `dom-` | |
| 4 | `./dbcopy.sh swap kubeletto_next --yes`, then `./dbcopy.sh clean` | exit 0; `kubeletto_prev` exists (the rollback copy of the empty-cluster state, drop it after the +24 h check) | |
| 5 | `./secrets.sh --live` (prod is still up: freshest values), then `./secrets.sh verify` | `0 differ` for the shared keys | |
| 6 | In the Kubeletto worktree `git switch cutover-live`, then `./apply.sh platform` | core Ready; `/readyz` 200 through the monitoring path | |
| 7 | Core in worker mode loops over the new database; check logs for errors, no events replayed (`check` was clean) | no `ERROR` for 5 min | |
| 8 | `./restore.sh run`, read the counts, then `./restore.sh run --apply` | restored = listed − unknown; every `ksvc` Ready; `K8sPodUnschedulable` silent | **yes** (starts every tenant's code at home) |
| 9 | **DNS flip**: see below | external `curl https://api.kubeletto.com/readyz` is home's | **yes** |
| 10 | Post-flip checks: console login, one tenant app, a GitHub push to a linked repo deploys at home (webhooks reach `api.kubeletto.com`, no GitHub change), one custom domain goes ACTIVE | all pass | |
| 11 | Deploy the new console: Kubeletto `scripts/deploy-console.sh` (Cloudflare Pages project `kubeletto-console`, from `home-migration`) | custom-domain dialog shows the ALIAS / CNAME target, not an empty "Target IPs" box | operator, or the agent if the token has Pages edit; recommended, not blocking: the old console works against the new API; rollback = redeploy the previous Pages build from the dashboard |

Smoke test before step 9 (no DNS needed): from VM 300, `curl` a sample of
tenant hostnames against Traefik with the Host header and the fixed SNI
`saas-origin.kubeletto.app`, as in "Custom domains" in the migration runbook.

### Step 9, the DNS flip

Three records change (`*.kubeletto.app` and `api.kubeletto.com` become proxied
CNAMEs to the tunnel; `domains.kubeletto.app` a proxied CNAME to
`saas-origin.kubeletto.app`, Cloudflare for SaaS). **Not with a bare
`tofu apply`**: a type change makes the provider destroy then create each
record, a gap on `*.kubeletto.app` in which a resolver can cache "does not
exist". `flip.sh` changes the type in place through the API (tested 2026-10-14):

```bash
cd network/cloudflare
git switch cutover-flip                  # the code is the "after"
./flip.sh forward                        # dry run: current and wanted values
./flip.sh forward --apply                # three in-place PATCHes, each verified
sops exec-env secrets.sops.env 'tofu plan'   # must say: No changes
```

Records are proxied, so the switch is at Cloudflare's edge within seconds and so
is the rollback. After the +24 h check, remove the rehearsal names
`home-api.kubeletto.com` and `probe-rehearsal.kubeletto.app` (with the matching
ingress rule in `tunnel.tf`) and the canary tenant's gate in `saas.tf`, then
merge `cutover-flip` (and `cutover-live` in the Kubeletto worktree).

## Rollback (until 2026-11-05)

1. `cd network/cloudflare && ./flip.sh back --apply` (the three records back to
   the rented server, in place), then `git switch main` and `tofu plan` must say
   No changes.
2. Prod: `kubectl -n platform scale deploy platform-core --replicas=1`.
3. Home: scale `platform-core` to 0 so it stops writing.

**The data window**: prod resumes on Aiven, and everything written at home
after step 4 (sign-ups, deploys, usage) is lost. Tenant apps at prod were never
touched, so they are as they were. Accepted: cost over production-readiness.

## After

- **+24 h**: watch `K8sPodUnschedulable`, `K8sNodeMemoryRequestsHigh`, 5xx at
  Traefik, and the nightly PBS job.
- **After 2026-11-05** (rented server gone, no rollback left): delete Aiven and
  Upstash 7 days after the cutover (decision D6), after one last look that
  nothing at home still reads them (`DATABASE_URL` and `REDIS_URL` point home
  since step 5).
- Housekeeping: README status, ADR 0011 status, the `kubeletto-prod` SSH alias,
  `docs/incidents` for anything that broke, and the Infisical project stays.
