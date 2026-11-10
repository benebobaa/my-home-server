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
./apply.sh diff          # read-only: what the platform overlay would change
./apply.sh drift         # same, exit 1 if the cluster differs from the repo
./apply.sh nodes         # read-only: is every K3s node admitted by the registry policies?
./tenant-bandwidth.sh [secs]   # read-only: which tenant namespace uses the network (names tenant + plan)
./weekly-review.sh            # read-only: the weekly 15-minute tenant review (network, churn, crash loops, traffic, always-on tenants, accounts)
./pin.sh running         # pin the overlay's own images to the digests the cluster runs
./pin.sh set core <sha8> <sha256:...>   # pin a new build (digest from the images run)
```

`apply.sh` renders the overlay at the worktree's checked-out commit (it
prints the commit, warns when `infra/k8s` is dirty). The cluster API is not
reachable from the LAN side, so the scripts go through root SSH to pve2 and
VM 300's guest agent (stdin capped at 1 MiB, hence the chunked apply).

**Look before you apply.** Run `./apply.sh diff` first: it server-side diffs
the rendered overlay against the cluster and changes nothing. `drift` is the
same with an exit status (0 matches, 1 differs, 2 could not tell) and runs as
part of `make drift`, so a hand edit on the cluster shows up like any other
drift. `KUBELETTO_REPO` picks the checkout compared (default `kubeletto-home`),
so drift is only meaningful against the commit that is meant to be running.
Proven 2026-11-06 with a positive control (a worktree with one env value
flipped reported the `-"false"`/`+"true"` change and exit 1) and a negative
one (the real overlay reported no drift, exit 0). The `diff` covers the
`platform` overlay only, not Knative, Kourier or Traefik (upstream YAML and a
Helm chart) or the Secrets created outside git.

**Weekly review.** `./weekly-review.sh` is the 15-minute review of operating-model
D19/D23 in one report: who uses the line, which free apps cold-start more than
200 pods a day (a pinger waking a scale-to-zero app), which containers crash-loop,
the top services by requests with their error share, which tenants never scale to zero (a lead for proxy/tunnel templates), and the account counts. It
only reads (the cluster through `pve2`, Prometheus, the Kubeletto database), names
tenants by slug and plan, and decides nothing: pausing a service stays the
operator's call. First run 2026-11-06: it put one free tenant first on the network
(82 % of the node's inbound), found six churners (240 to 715 pods a day) and the
one crash loop.

**Adding a node.** Containerd on every node pulls tenant images from the
registry and the Docker Hub mirror, and that traffic arrives from the node's own
address in its pod subnet (`10.42.<n>.0`), which `policies.yaml` lists as `/32`
entries (the CIDR cannot be widened: tenant pods are in the same range). A node
that joins without its entry cannot pull images and nothing says why.
`./apply.sh nodes` compares every node's pod subnet with those policies and
names the line to add; `drift` runs it too. Proven 2026-11-06 on the live two
nodes (both admitted) and with a simulated third (`EXTRA_NODES="k3s-worker2
10.42.2.0/24" ./apply.sh nodes` fails and names it). Traefik's `trustedIPs`
(`10.42.0.0/24`) is deliberately the server node only and needs no change for a
worker.

**Pinned images.** A tag can be re-pushed to different content; a digest cannot.
`pin.sh` writes `digest: sha256:...` next to `newTag` for Kubeletto's own
image (core) in `infra/k8s/home/kustomization.yaml`; kustomize
renders `image:tag@sha256:...`, so the tag stays readable and the digest is
what runs. After a green `main` build the `images` workflow prints each digest
in its run summary: `./pin.sh set core <sha8> <digest>`, then `./apply.sh diff`,
then apply. `running` pins what the cluster runs now and refuses when the
cluster's tag differs from the overlay's, or two versions run at once.
Applying the first pin changes the pod template (`tag` becomes `tag@digest`),
so core rolls once: do it in a quiet moment. `pin.sh` does not talk to
the registry (the packages are private and the `gh` token has no
`read:packages`); resolving a digest from GHCR needs that scope.

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
VictoriaLogs (`logs`, 8 days of tenant logs: every plan may query 7, Kubeletto D12) and the Docker Hub mirror cache
(rebuildable). The database is CT 130's (nightly dump + PBS). A rebuild is
VM 300/301 from `proxmox/opentofu`, then Converge.

## History

Phase 1 (2026-10-11) ran prod's live image built from prod's exported
objects; that stack was replaced the same day by the overlay. The database
copy skips `usage_samples` rows: Aiven delivers ~140 KB/s per connection.
