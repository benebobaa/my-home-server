#!/usr/bin/env bash
# Migrate larasrouter's database on the shared Postgres by hand, before a release
# (larasrouter docs/production-launch.md §3: DB_MIGRATE_ON_START=false). From the
# operator Mac through tunnel.py, with a snapshot first and a confirmation.
#
#   ./migrate.sh status            what is applied and pending, nothing changes
#   ./migrate.sh up [--yes]        snapshot, show pending, confirm, goose up, seed, verify
#
# Runs the larasrouter checkout's migrations and seeds (LARAS_REPO, default
# ~/Documents/benelabs/larasrouter): check out the commit you are about to
# release first. Calls goose directly with the repo's pinned version, never
# `make migrate-up` (it sources a .env that can override DATABASE_URL) and never
# down/reset/fresh. The password is read from OpenTofu state into the environment
# of the child processes, never printed. Rollback = restore the snapshot:
#   pg_restore -d <empty db> ... (the file is in SNAP_DIR, see below).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${LARAS_REPO:-$HOME/Documents/benelabs/larasrouter}
API=$REPO/services/api
SNAP_DIR=${LARAS_SNAPSHOTS:-$HOME/Documents/benelabs/larasrouter-db-snapshots}
PGBIN=/opt/homebrew/opt/libpq/bin
GOOSE_VERSION=$(grep -E '^GOOSE_VERSION' "$API/Makefile" | head -1 | sed 's/.*= *//')
LOCAL_PORT=15432
MODE=${1:-}; YES=0; [ "${2:-}" = --yes ] && YES=1
[[ $MODE =~ ^(status|up)$ ]] || { sed -n 2,14p "$0" >&2; exit 2; }
[ -d "$API/db/migrations" ] || { echo "no migrations at $API/db/migrations (LARAS_REPO?)" >&2; exit 1; }

# The tunnel: use the one that is running, else start ours and stop it at exit.
TUN_PID=""
if ! nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
  python3 "$HERE/tunnel.py" db >/dev/null 2>&1 & TUN_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null && break; sleep 0.5; done
fi
cleanup() { [ -z "$TUN_PID" ] || kill "$TUN_PID" 2>/dev/null || true; }
trap cleanup EXIT

PW=$(cd "$HERE/../../proxmox/opentofu" && echo 'nonsensitive(random_password.postgres["larasrouter"].result)' |
  sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tail -n1 | tr -d '"\n')
export DATABASE_URL="postgres://larasrouter:${PW}@127.0.0.1:${LOCAL_PORT}/larasrouter?sslmode=require"
export GOOSE_DRIVER=postgres GOOSE_DBSTRING="$DATABASE_URL" GOOSE_MIGRATION_DIR="$API/db/migrations"
[[ $PW =~ ^[A-Za-z0-9]{32}$ ]] || { echo 'refusing: the password read from OpenTofu is not 32 alphanumerics' >&2; exit 1; }
unset PW

# The target must be the larasrouter database on the shared Postgres (10.10.20.21).
who=$("$PGBIN/psql" "$DATABASE_URL" -X -A -t -c "select current_database()||' '||host(inet_server_addr())")
[ "$who" = "larasrouter 10.10.20.21" ] || { echo "refusing: connected to '$who', expected 'larasrouter 10.10.20.21'" >&2; exit 1; }
echo "target: $who (through the tunnel)"
echo "source: $(git -C "$REPO" rev-parse --short HEAD) on $(git -C "$REPO" branch --show-current)$(git -C "$REPO" status --porcelain -- services/api/db | grep -q . && echo ' (db/ HAS UNCOMMITTED CHANGES)')"

goose() { (cd "$API" && go run "github.com/pressly/goose/v3/cmd/goose@${GOOSE_VERSION}" "$@"); }

echo "--- goose status"
goose status 2>&1 | grep -v -E '^\s*$' | tail -12
pending=$(goose status 2>&1 | grep -c 'Pending' || true)
echo "pending migrations: $pending"
[ "$MODE" = up ] || exit 0

if [ "$pending" = 0 ]; then
  echo "nothing to migrate; running the idempotent seeds only"
else
  mkdir -p "$SNAP_DIR" && chmod 700 "$SNAP_DIR"
  snap="$SNAP_DIR/larasrouter-pre-$(date +%Y%m%d-%H%M%S).dump"
  "$PGBIN/pg_dump" -Fc --no-owner --no-acl "$DATABASE_URL" -f "$snap"
  chmod 600 "$snap"
  echo "snapshot: $snap ($(wc -c <"$snap") bytes)"
  # keep the 10 newest snapshots
  find "$SNAP_DIR" -name 'larasrouter-pre-*.dump' -print0 | xargs -0 ls -1t 2>/dev/null | tail -n +11 | while read -r old; do rm -f "$old"; done
fi
if [ "$YES" != 1 ]; then
  read -r -p "type 'migrate' to apply $pending migration(s) to the larasrouter database: " ans
  [ "$ans" = migrate ] || { echo "aborted"; exit 1; }
fi
[ "$pending" = 0 ] || goose up
(cd "$API" && go run ./cmd/seed -dir db/seed)
echo "--- after"
goose status 2>&1 | grep -v -E '^\s*$' | tail -4
left=$(goose status 2>&1 | grep -c 'Pending' || true)
if [ "$left" = 0 ]; then echo "schema current"; else echo "STILL PENDING: $left" >&2; exit 1; fi
echo "readiness (the live app, informational): $(curl -s -m 10 https://api.larasrouter.com/health/ready | head -c 120)"
