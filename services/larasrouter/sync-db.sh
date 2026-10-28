#!/usr/bin/env bash
# Copy larasrouter's production database (its own Aiven service) into its
# database on the shared Postgres (CT 130), owner larasrouter. Read-only on the
# source. REPLACES the target's contents every run, so it refuses once the app
# is connected to the target (that is the flip: after it, never run it again).
#
#   ./sync-db.sh check    row counts on both sides, nothing copied
#   ./sync-db.sh run      dump, drop the target's schema, restore, compare
#
# The source URL is read from the tenant's own Secret in the cluster and never
# printed. Needs pg_dump 18 (brew libpq).
set -euo pipefail
NODE=root@10.10.10.12 VMID=300 NS=kl-f42a6fae-f42a6fae ENV_OBJECT=svc-85e9ba31-env
PGBIN=/opt/homebrew/opt/libpq/bin
MODE=${1:-check}
[[ $MODE =~ ^(check|run)$ ]] || { sed -n 2,12p "$0" >&2; exit 2; }

src_url() {
  ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --timeout 40 -- /usr/local/bin/k3s kubectl -n $NS get secret $ENV_OBJECT -o jsonpath={.data.DATABASE_URL}" |
    python3 -c 'import sys,json,base64; sys.stdout.write(base64.b64decode(json.load(sys.stdin)["out-data"]).decode())'
}
ct() { ssh -o BatchMode=yes "$NODE" "pct exec 130 -- su postgres -c \"$1\""; }
SRC=$(src_url)
export PGCONNECT_TIMEOUT=15

# Exact counts on both sides (n_live_tup is an estimate: count the big ones for real).
exact_sql="select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"
counts() { # $1 = "src" | "dst"
  local tabs t out=""
  if [ "$1" = src ]; then tabs=$("$PGBIN/psql" "$SRC" -X -A -t -c "$exact_sql")
  else tabs=$(ct "psql -d larasrouter -X -A -t -c \\\"$exact_sql\\\""); fi
  for t in $tabs; do
    if [ "$1" = src ]; then n=$("$PGBIN/psql" "$SRC" -X -A -t -c "select count(*) from \"$t\"")
    else n=$(ct "psql -d larasrouter -X -A -t -c \\\"select count(*) from \\\\\\\"$t\\\\\\\"\\\""); fi
    out+="$t=$n "
  done
  echo "$out"
}

if [ "$MODE" = check ]; then
  echo "source: $(counts src | wc -w) tables; target: $(counts dst | wc -w) tables"
  diff <(counts src | tr ' ' '\n') <(counts dst | tr ' ' '\n') >/dev/null && echo "row counts equal" || echo "row counts differ"
  exit 0
fi

live=$(ct "psql -d postgres -X -A -t -c \\\"select count(*) from pg_stat_activity where datname='larasrouter' and client_addr='10.10.25.21'\\\"")
[ "${live:-0}" = 0 ] || { echo "refusing: the app is connected to the target ($live sessions): it is live there" >&2; exit 1; }

DUMP=$(mktemp)
trap 'rm -f "$DUMP"' EXIT
chmod 600 "$DUMP"
"$PGBIN/pg_dump" -Fc --no-owner --no-acl "$SRC" -f "$DUMP"
echo "dump: $(wc -c <"$DUMP") bytes"
ct "psql -d larasrouter -X -v ON_ERROR_STOP=1 -c \\\"drop schema if exists public cascade; create schema public authorization larasrouter; grant all on schema public to larasrouter\\\"" >/dev/null
ssh -o BatchMode=yes "$NODE" "pct exec 130 -- su postgres -c 'pg_restore -d larasrouter --no-owner --no-acl --role=larasrouter --exit-on-error'" <"$DUMP"
echo "restored; comparing row counts"
diff <(counts src | tr ' ' '\n') <(counts dst | tr ' ' '\n') && echo "row counts equal on all tables"
