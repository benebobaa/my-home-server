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
./secrets.sh             # Secrets: shared ones from prod, home ones generated
./apply.sh               # base, knative, traefik, platform (overlay), rehearsal
```

`apply.sh` renders the overlay at the worktree's checked-out commit (it
prints the commit, warns when `infra/k8s` is dirty). The cluster API is not
reachable from the LAN side, so the scripts go through root SSH to pve2 and
VM 300's guest agent (stdin capped at 1 MiB, hence the chunked apply).

Not in git, added at apply time: the home public IPv4 (tenant and build
egress deny lists) and the operator's IPv6 /64 (the `home-api` allowlist).

## Rehearsal names

`home-api.kubeletto.com` (operator IPv6 /64 only: it serves a copy of
production data) and `probe-rehearsal.kubeletto.app` (a hello-world Knative
Service on the worker). Both are removed at cutover with their DNS records
in `network/cloudflare/tunnel.tf`.

## State

Stateless except NATS JetStream (`nats-data`, events in flight),
VictoriaLogs (`logs`, 7 days of tenant logs) and the Docker Hub mirror cache
(rebuildable). The database is CT 130's (nightly dump + PBS). A rebuild is
VM 300/301 from `proxmox/opentofu`, then Converge.

## History

Phase 1 (2026-10-11) ran prod's live image built from prod's exported
objects; that stack was replaced the same day by the overlay. The database
copy skips `usage_samples` rows: Aiven delivers ~140 KB/s per connection.
