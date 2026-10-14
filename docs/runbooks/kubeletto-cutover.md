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
7. Prepare, do not apply:
   - Kubeletto `infra/k8s/home/platform-core-patch.yaml`: delete the
     `DOMAINS_RECONCILE_TENANTS` line (commit on `home-migration`).
   - `network/cloudflare/records.tf` and `tunnel.tf`: the edits of step 9.

## The day

| # | Step | Verify | Needs the operator's yes |
| --- | --- | --- | --- |
| 0 | `./restore.sh list` (prod's tenant Knative services, read-only; saved in `~/.cache/kubeletto-restore/`, apart from the dump's directory, which step 2 wipes) | "listed N tenant services" | |
| 1 | Prod: let in-flight builds finish, then `ssh kubeletto-prod kubectl -n platform scale deploy platform-core --replicas=0` | prod `/readyz` fails; tenant apps still answer | **yes** (API and deploys down) |
| 2 | `./dbcopy.sh dump && ./dbcopy.sh restore kubeletto_next && KUBELETTO_DB=kubeletto_next ./migrate.sh up && ./dbcopy.sh check kubeletto_next` | `goose version 100`, `clean` | |
| 3 | Home: scale `platform-core` to 0; delete all `dom-*` IngressRoutes and Middlewares in ns `traefik` | `kubectl -n traefik get ingressroute` lists none starting `dom-` | |
| 4 | `./dbcopy.sh swap kubeletto_next --yes`, then `./dbcopy.sh clean` | exit 0; `kubeletto_prev` exists (the rollback copy of the empty-cluster state, drop it after the +24 h check) | |
| 5 | `./secrets.sh --live` (prod is still up: freshest values), then `./secrets.sh verify` | `0 differ` for the shared keys | |
| 6 | Apply the patch of step 7 above: `./apply.sh platform` | core Ready; `/readyz` 200 through the monitoring path | |
| 7 | Core in worker mode loops over the new database; check logs for errors, no events replayed (`check` was clean) | no `ERROR` for 5 min | |
| 8 | `./restore.sh run`, read the counts, then `./restore.sh run --apply` | restored = listed − unknown; every `ksvc` Ready; `K8sPodUnschedulable` silent | **yes** (starts every tenant's code at home) |
| 9 | **DNS flip**: see below | external `curl https://api.kubeletto.com/readyz` is home's | **yes** |
| 10 | Post-flip checks: console login, one tenant app, a GitHub push to a linked repo deploys at home (webhooks reach `api.kubeletto.com`, no GitHub change), one custom domain goes ACTIVE | all pass | |
| 11 | Deploy the new console: Kubeletto `scripts/deploy-console.sh` (Cloudflare Pages project `kubeletto-console`, from `home-migration`) | custom-domain dialog shows the ALIAS / CNAME target, not an empty "Target IPs" box | operator, or the agent if the token has Pages edit; recommended, not blocking: the old console works against the new API; rollback = redeploy the previous Pages build from the dashboard |

Smoke test before step 9 (no DNS needed): from VM 300, `curl` a sample of
tenant hostnames against Traefik with the Host header and the fixed SNI
`saas-origin.kubeletto.app`, as in "Custom domains" in the migration runbook.

### Step 9, the DNS flip

In `network/cloudflare/records.tf`:

- `app_wildcard_a` (`*.kubeletto.app`) and `com_api_a` (`api.kubeletto.com`):
  from the A record `103.59.160.198` to a proxied CNAME
  `<tunnel id>.cfargotunnel.com` (the rehearsal names in `tunnel.tf` show the
  form).
- `app_domains_a` (`domains.kubeletto.app`): from the DNS-only A record to a
  **proxied CNAME to `saas-origin.kubeletto.app`** (Cloudflare for SaaS; the
  custom hostnames then validate and go ACTIVE on their own).
- Delete the rehearsal names `home-api.kubeletto.com` and
  `probe-rehearsal.kubeletto.app` and the matching ingress rule.
- Remove `DOMAINS_RECONCILE_TENANTS` from the core patch (step 6 already
  applied it) and the canary tenant's gate in `saas.tf`.

`sops exec-env secrets.sops.env 'tofu plan'` must show exactly those changes,
then apply. Records are proxied, so the switch is at Cloudflare's edge within
seconds and so is the rollback.

## Rollback (until 2026-11-05)

1. `records.tf`: the three records back to their old values (`git revert` the
   flip commit), `tofu apply`.
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
