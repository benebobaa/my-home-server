# kubeletto — the PaaS platform on the home K3s cluster

Kubeletto (repo `podpilott/kubeletto`, worktree
`~/Documents/benelabs/kubeletto-home`, branch `home-migration`) moving home
from the rented server ([ADR 0011](../../docs/decisions/0011-kubeletto-on-the-home-cluster.md),
deadline 2026-11-05). Kubeletto's own decisions and phases:
`docs/migration/README.md` in that repo. Inventory, safety switches and what
must never run: [runbooks/kubeletto-migration.md](../../docs/runbooks/kubeletto-migration.md).

## Who owns what

| | Where |
| --- | --- |
| The platform's in-cluster objects (core, NATS, Valkey, registry, logs, routes, Knative settings, policies) and the upstream versions | Kubeletto repo, `infra/k8s/home/` (`versions.env`) |
| Images (`ghcr.io/podpilott/kubeletto-core`, `kubeletto-build-worker`) | Kubeletto's `images` workflow (GitHub Actions) |
| K3s, the tunnel connector, the database (CT 130), and the tooling that applies the overlay | this repo |

## Converge

```bash
cd services/kubeletto
./migrate.sh status|up   # goose against the HOME database copy (never prod)
./dbcopy.sh dump|restore|check|swap|drop   # prod -> CT 130 copy for the cutover:
                         # restores into a NEW database, never over the live one
                         # (runbook kubeletto-migration.md, "Cutover: database")
./restore.sh list|run    # no tenant app exists on a fresh cluster: redeploy each
                         # service that ran on prod from its stored image
./secrets.sh snapshot|verify|--from-snapshot|--live   # prod secrets survive prod
./secrets.sh             # Secrets: shared ones from prod, home ones generated
./apply.sh               # base, knative, traefik, platform (overlay), rehearsal
```

`apply.sh` renders the overlay at the worktree's checked-out commit (it
prints the commit, warns when `infra/k8s` is dirty). The cluster API is not
reachable from the LAN side, so the scripts go through root SSH to pve2 and
VM 300's guest agent (stdin capped at 1 MiB, hence the chunked apply).

Not in git, added at apply time: the home public IPv4 (tenant and build
egress deny lists) and the operator's IPv6 /64 (the `home-api` allowlist).

## Database from the Mac (GUI)

```bash
python3 ../larasrouter/tunnel.py db     # keep running; Ctrl-C stops it
./db-password.sh | pbcopy               # the kubeletto role's password, clipboard only
```

GUI client: host `127.0.0.1`, port `15432`, database and user `kubeletto`,
password from the clipboard, `sslmode=require`. Verified 2026-10-28: TLS 1.3
through the tunnel and a login as `kubeletto` (56 tables, goose 101).

## Rehearsal names

`home-api.kubeletto.com` (operator IPv6 /64 only: it serves a copy of
production data) and `probe-rehearsal.kubeletto.app` (a hello-world Knative
Service on the worker). Both are removed at cutover with their DNS records
in `network/cloudflare/tunnel.tf`.

## State

Stateless except the registry's blobs (VM 300's second disk mounted at
`/mnt/registry`, no backup, [ADR 0021](../../docs/decisions/0021-registry-on-the-k3s-servers-own-disk.md);
`registry-copy.sh` copies a bucket onto it), NATS JetStream (now on the shared hub),
VictoriaLogs (`logs`, 7 days of tenant logs) and the Docker Hub mirror cache
(rebuildable). The database is CT 130's (nightly dump + PBS). A rebuild is
VM 300/301 from `proxmox/opentofu`, then Converge.

## History

Phase 1 (2026-10-11) ran prod's live image built from prod's exported
objects; that stack was replaced the same day by the overlay. The database
copy skips `usage_samples` rows: Aiven delivers ~140 KB/s per connection.
