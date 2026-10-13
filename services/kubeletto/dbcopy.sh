#!/usr/bin/env bash
# Copy production's Kubeletto database into CT 130 (the home Postgres).
# Rehearsed 2026-10-14; the same stages are the cutover's data step
# (docs/runbooks/kubeletto-migration.md, "Cutover: database").
#
#   ./dbcopy.sh dump              pg_dump on prod -> local scratch dir
#   ./dbcopy.sh restore [db]      push to CT 130, restore into NEW db (default kubeletto_next)
#   KUBELETTO_DB=kubeletto_next ./migrate.sh up      (goose, then:)
#   ./dbcopy.sh check [db]        preflight: nothing pending a worker would replay
#   ./dbcopy.sh swap [db] --yes   rename live kubeletto -> kubeletto_prev, db -> kubeletto
#   ./dbcopy.sh drop <db>         drop a scratch database
#
# Nothing here writes to the live `kubeletto` database except `swap`, and
# swap refuses while anything is connected: scale the home core to 0 first.
#
# Prod side: ONE requests-free pod (the node sits at its memory-request
# limit: a pod with requests starves tenant cold starts, incident
# 2026-10-11) that dumps over Aiven's allowlisted path and is deleted when
# the dump is off the node. Rows of usage_samples (941 MB of 1.16 GB, the
# metering history, decision D3) and openobserve_read_model_exports are not
# copied. Run `dump` only after the operator has frozen prod's writes
# (cutover) or accepts a point-in-time copy (rehearsal).
set -euo pipefail
cd "$(dirname "$0")"

PROD=${KUBELETTO_PROD_SSH:-kubeletto-prod}   # ssh alias, ~/.ssh/config
NODE=root@10.10.10.12                        # pve2, hosts CT 130
CT=130
OUT=${KUBELETTO_DUMP_DIR:-${TMPDIR:-/tmp}/kubeletto-dump}
POD=kubeletto-dbcopy-pgdump
LIVE=${KUBELETTO_LIVE_DB:-kubeletto}   # only ever overridden to rehearse `swap` on scratch databases
ROLE=kubeletto

step() { printf '== %s\n' "$*" >&2; }
timed() { local t=$SECONDS; "$@"; printf '   %ss\n' "$((SECONDS - t))" >&2; }
ct() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$NODE" "pct exec $CT -- bash -s"; }
valid_db() { [[ $1 =~ ^[a-z_][a-z0-9_]{0,40}$ ]] || { echo "bad database name: $1" >&2; exit 2; }; }
psql_ct() { # psql_ct <db> <sql>: as postgres inside CT 130, SQL on stdin of the guest
  printf 'su postgres -c "psql -v ON_ERROR_STOP=1 -X -d %s -At" <<"SQL"\n%s\nSQL\n' "$1" "$2" | ct
}

cmd_dump() {
  step "pg_dump on prod ($PROD), directory format, -j4, no usage_samples rows"
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROD" "kubectl -n platform delete pod $POD --ignore-not-found >/dev/null 2>&1" || true
  sed "s/@POD@/$POD/" <<'EOF' | ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROD" 'kubectl apply -f - >/dev/null'
apiVersion: v1
kind: Pod
metadata: {name: @POD@, namespace: platform, labels: {purpose: migration-dbcopy}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  - name: pg
    image: docker.io/library/postgres:18-alpine
    command:
    - sh
    - -c
    - |
      # Aiven is slow and uneven (~140 KB/s to 1 MB/s): github_webhook_deliveries
      # alone is a 64 MB single-table COPY that no -j can split, so 1 to 8
      # min (a 7 min cap killed it twice on 2026-10-14). Keepalives drop a
      # dead socket; the timeout only guards against a wedge; 2 attempts.
      url="$DATABASE_URL_DIRECT&keepalives=1&keepalives_idle=20&keepalives_interval=10&keepalives_count=3&connect_timeout=20"
      rc=1
      for attempt in 1 2; do
        rm -rf /dump/db
        timeout 1500 pg_dump "$url" -Fd -j4 -Z3 --no-owner --no-acl \
          --exclude-table-data=usage_samples --exclude-table-data=openobserve_read_model_exports \
          -f /dump/db 2>/dump/err && rc=0 && break
        rc=$?
        echo "attempt $attempt rc=$rc" >>/dump/attempts
      done
      echo $rc >/dump/rc
      sleep 3600
    envFrom: [{secretRef: {name: platform-core-env}}]
    resources: {}
    volumeMounts: [{name: dump, mountPath: /dump}]
  volumes: [{name: dump, emptyDir: {sizeLimit: 2Gi}}]
EOF
  # Wait for the dump (rc file), up to 30 min; the pod is deleted either way.
  trap 'ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROD" "kubectl -n platform delete pod $POD --wait=false >/dev/null 2>&1" || true' EXIT
  # Each poll is bounded (`timeout 20`): a kubectl exec through the API once
  # never returned and stalled the whole wait for 20+ min (2026-10-14).
  timed ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 "$PROD" "for i in \$(seq 1 200); do timeout 20 kubectl -n platform exec $POD -- test -f /dump/rc 2>/dev/null && break; sleep 15; done; timeout 20 kubectl -n platform exec $POD -- cat /dump/rc" >"$OUT.rc" 2>/dev/null || true
  [ "$(tr -d '[:space:]' <"$OUT.rc" 2>/dev/null)" = 0 ] || { echo "pg_dump did not finish cleanly (rc file: $(cat "$OUT.rc" 2>/dev/null))" >&2; exit 1; }
  step "pull to $OUT"
  rm -rf "$OUT" && mkdir -p "$OUT"
  timed bash -c "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 '$PROD' 'kubectl -n platform exec $POD -- tar -C /dump -cf - db 2>/dev/null' | tar -C '$OUT' -xf -"
  [ -f "$OUT/db/toc.dat" ] || { echo "pulled dump has no toc.dat" >&2; exit 1; }
  du -sh "$OUT/db" >&2
}

cmd_restore() {
  local db=${1:-kubeletto_next}; valid_db "$db"
  [ "$db" != "$LIVE" ] || { echo "restore never targets the live database" >&2; exit 2; }
  [ -f "$OUT/db/toc.dat" ] || { echo "no dump at $OUT (run: $0 dump)" >&2; exit 2; }
  step "push to CT $CT"
  timed bash -c "COPYFILE_DISABLE=1 tar --no-xattrs -C '$OUT' -cf - db | ssh -o BatchMode=yes -o ConnectTimeout=15 '$NODE' 'cat >/var/tmp/kdump.tar && pct push $CT /var/tmp/kdump.tar /tmp/kdump.tar && rm /var/tmp/kdump.tar'"
  step "restore into $db (owner $ROLE, so goose and the app need no grants)"
  timed ct <<EOF
set -euo pipefail
rm -rf /tmp/kd && mkdir /tmp/kd && tar --no-same-owner -C /tmp/kd -xf /tmp/kdump.tar 2>/dev/null
find /tmp/kd -name '._*' -delete
chown -R postgres:postgres /tmp/kd
su postgres -c "dropdb --if-exists $db && createdb -O $ROLE $db"
su postgres -c "pg_restore -d $db -j2 --no-owner --no-acl --role=$ROLE /tmp/kd/db"
rm -rf /tmp/kd /tmp/kdump.tar
EOF
  psql_ct "$db" "select 'size', pg_size_pretty(pg_database_size('$db')); select 'goose', max(version_id) from goose_db_version; select 'tenants', count(*) from tenants;" >&2
}

# Rows a worker-mode core would replay or re-run on its first pass: pending or
# leased outbox events, builds not in a terminal state, pending webhook
# deliveries. At cutover prod is frozen and drained, so all three are 0; a
# non-zero count is a decision for the operator, not something to delete.
cmd_check() {
  local db=${1:-kubeletto_next}; valid_db "$db"
  step "preflight on $db"
  local out
  out=$(psql_ct "$db" "
select 'outbox_pending_or_processing', count(*) from outbox_events where status in ('pending','processing');
select 'builds_not_terminal', count(*) from builds where status not in ('completed','failed','superseded','cancelled');
select 'webhook_deliveries_pending', count(*) from github_webhook_deliveries where status = 'pending';
select 'goose_version', max(version_id) from goose_db_version;")
  printf '%s\n' "$out" >&2
  if printf '%s\n' "$out" | grep -E '^(outbox|builds|webhook)' | grep -vq '|0$'; then
    echo "NOT CLEAN: rows above would be replayed by a worker-mode core. Drain prod and dump again." >&2
    exit 1
  fi
  echo "clean" >&2
}

cmd_swap() {
  local db=${1:-kubeletto_next}; valid_db "$db"
  [ "${2:-}" = --yes ] || { echo "swap renames the LIVE database; pass --yes (home core must be scaled to 0)" >&2; exit 2; }
  step "swap: $LIVE -> ${LIVE}_prev, $db -> $LIVE"
  local conns
  conns=$(psql_ct postgres "select count(*) from pg_stat_activity where datname in ('$LIVE','$db') and pid <> pg_backend_pid();")
  [ "$conns" = 0 ] || { echo "$conns connection(s) still open on $LIVE/$db: scale the core to 0 and stop the exporters' sessions" >&2; exit 1; }
  psql_ct postgres "alter database $LIVE rename to ${LIVE}_prev; alter database $db rename to $LIVE;" >&2
}

cmd_drop() { local db=${1:?database}; valid_db "$db"; [ "$db" != "$LIVE" ] || { echo "not the live database" >&2; exit 2; }
  psql_ct postgres "drop database if exists $db;" >&2; }

case "${1:-}" in
  dump) cmd_dump ;;
  restore) shift; cmd_restore "$@" ;;
  check) shift; cmd_check "$@" ;;
  swap) shift; cmd_swap "$@" ;;
  drop) shift; cmd_drop "$@" ;;
  *) sed -n 2,12p "$0" >&2; exit 2 ;;
esac
