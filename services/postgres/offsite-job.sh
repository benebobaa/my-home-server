#!/usr/bin/env bash
# The off-site backup's recurring jobs (ADR 0034). Installed as
# /usr/local/sbin/pg-offsite by offsite.sh; runs as root, pgBackRest and psql
# as `postgres`. Writes node_exporter textfiles (scraped on :9100, alerts in
# services/monitoring/prometheus/rules/app-postgres.yml).
#
#   pg-offsite metrics   every 5 min (pg-offsite-metrics.timer), local only:
#                        when a WAL segment last reached the bucket
#                        (pg_stat_archiver: with archive-async, archive_command
#                        succeeds only once the segment is stored).
#   pg-offsite daily     04:00 WIB (pg-offsite-daily.timer), talks to B2: a
#                        full backup if the newest is older than ~3 days
#                        (pgBackRest expires down to 2 fulls after it), then
#                        the repo's size and the 10 GB guard.
#
# The guard: B2's free tier is 10 GB. Above 9 GB of files in the repo, expire
# down to ONE full (and its WAL) and record it (PostgresOffsiteGuardExpired).
# B2 deletes are hide markers until the bucket's lifecycle rule ("keep only
# the last version") removes them a day later; repo-ls cannot see those, which
# is why the guard sits 1 GB below the cap. B2's own $0 storage cap
# (operator setting) refuses writes past 10 GB; archive-push-queue-max then
# keeps pg_wal from filling.
#
# PG_OFFSITE_FAKE_REPO_BYTES replaces the measured size (the guard test in
# docs/experiments/2026-11-09-pgbackrest-offsite-local.md).
set -euo pipefail

STANZA=main
TEXTFILE=/var/lib/prometheus/node-exporter
STATE=/var/lib/pg-offsite
FULL_EVERY=$((66 * 3600))      # "every 3 days" for a daily timer: due after 2.75 days
GUARD_BYTES=${PG_OFFSITE_GUARD_BYTES:-9000000000}

as_pg() { runuser -u postgres -- "$@"; }
pgbr() { as_pg pgbackrest --stanza="$STANZA" "$@"; }

# Write a textfile atomically (node_exporter must never read half a file).
write_prom() {
  local name=$1 tmp
  tmp=$(mktemp "$TEXTFILE/.${name}.XXXXXX")
  cat > "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$TEXTFILE/${name}.prom"
}

metrics() {
  local row last failed ready prev=0
  row=$(as_pg psql -XAt -F' ' -c "SELECT coalesce(extract(epoch FROM last_archived_time)::bigint, 0), failed_count FROM pg_stat_archiver")
  read -r last failed <<<"$row"
  ready=$(as_pg psql -XAtc "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'")
  # pg_stat_archiver resets after a crash: keep the newest time ever seen,
  # so a reset is not mistaken for a stale archive (or the other way round).
  [ -s "$STATE/archive_last" ] && prev=$(cat "$STATE/archive_last")
  [ "$last" -gt "$prev" ] || last=$prev
  echo "$last" > "$STATE/archive_last"
  {
    echo "# HELP pg_offsite_archive_last_success_timestamp_seconds When a WAL segment last reached the off-site bucket."
    echo "# TYPE pg_offsite_archive_last_success_timestamp_seconds gauge"
    [ "$last" -gt 0 ] && echo "pg_offsite_archive_last_success_timestamp_seconds $last"
    echo "# HELP pg_offsite_archive_failed_total Failed archive_command runs since the last stats reset."
    echo "# TYPE pg_offsite_archive_failed_total counter"
    echo "pg_offsite_archive_failed_total $failed"
    echo "# HELP pg_offsite_archive_ready_segments WAL segments in pg_wal waiting to be archived."
    echo "# TYPE pg_offsite_archive_ready_segments gauge"
    echo "pg_offsite_archive_ready_segments $ready"
  } | write_prom pg_offsite_archive
}

last_full() { jq -r '[.[0].backup[]? | select(.type == "full") | .timestamp.stop] | max // 0'; }
fulls() { jq -r '[.[0].backup[]? | select(.type == "full")] | length'; }
repo_bytes() {
  if [ -n "${PG_OFFSITE_FAKE_REPO_BYTES:-}" ]; then
    echo "$PG_OFFSITE_FAKE_REPO_BYTES"
  else
    as_pg pgbackrest repo-ls --recurse --output=json | jq -r '[.[] | select(.type == "file") | .size] | add // 0'
  fi
}

daily() {
  local info full now bytes guard_ts=0
  now=$(date +%s)
  info=$(pgbr info --output=json)
  full=$(last_full <<<"$info")
  if [ "$full" = 0 ]; then
    echo "pg-offsite: no full backup yet: full backup"
    pgbr --type=full backup
    info=$(pgbr info --output=json)
    full=$(last_full <<<"$info")
  elif [ $((now - full)) -ge "$FULL_EVERY" ]; then
    echo "pg-offsite: newest full is $(((now - full) / 3600)) h old: full backup"
    pgbr --type=full backup
    info=$(pgbr info --output=json)
    full=$(last_full <<<"$info")
  else
    echo "pg-offsite: newest full is $(((now - full) / 3600)) h old: none due"
  fi

  bytes=$(repo_bytes)
  if [ "$bytes" -gt "$GUARD_BYTES" ]; then
    echo "pg-offsite: GUARD: repo holds ${bytes} bytes (> ${GUARD_BYTES}): expiring down to one full backup" >&2
    pgbr expire --repo1-retention-full=1
    date +%s > "$STATE/guard_last"
    info=$(pgbr info --output=json)
    bytes=$(repo_bytes)
    echo "pg-offsite: GUARD: repo now ${bytes} bytes" >&2
  fi
  [ -s "$STATE/guard_last" ] && guard_ts=$(cat "$STATE/guard_last")

  {
    echo "# HELP pg_offsite_full_backup_last_timestamp_seconds When the newest full backup in the bucket finished."
    echo "# TYPE pg_offsite_full_backup_last_timestamp_seconds gauge"
    [ "$full" -gt 0 ] && echo "pg_offsite_full_backup_last_timestamp_seconds $full"
    echo "# HELP pg_offsite_full_backups Full backups in the bucket."
    echo "# TYPE pg_offsite_full_backups gauge"
    echo "pg_offsite_full_backups $(fulls <<<"$info")"
    echo "# HELP pg_offsite_repo_bytes Bytes of files in the bucket's repo (B2 hidden versions not included)."
    echo "# TYPE pg_offsite_repo_bytes gauge"
    echo "pg_offsite_repo_bytes $bytes"
    echo "# HELP pg_offsite_guard_last_expire_timestamp_seconds When the 9 GB guard last expired down to one full (0: never)."
    echo "# TYPE pg_offsite_guard_last_expire_timestamp_seconds gauge"
    echo "pg_offsite_guard_last_expire_timestamp_seconds $guard_ts"
    echo "# HELP pg_offsite_daily_last_success_timestamp_seconds When the daily off-site job last completed."
    echo "# TYPE pg_offsite_daily_last_success_timestamp_seconds gauge"
    echo "pg_offsite_daily_last_success_timestamp_seconds $(date +%s)"
  } | write_prom pg_offsite_repo
  echo "pg-offsite: $(fulls <<<"$info") full backup(s), newest finished $(date -d "@$full" -u +%FT%TZ), repo ${bytes} bytes"
}

case "${1:-}" in
  metrics) metrics ;;
  daily) daily ;;
  *) echo "usage: pg-offsite metrics|daily" >&2; exit 2 ;;
esac
