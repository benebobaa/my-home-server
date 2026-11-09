#!/usr/bin/env bash
# postgres off-site copy: pgBackRest, WAL archiving and full backups into a
# Backblaze B2 bucket over its S3 API, encrypted before it leaves the CT
# (ADR 0034). Idempotent. Runs after setup.sh (it uses setup.sh's PGDG repo
# and node_exporter textfile directory).
#
# Run by OpenTofu (terraform_data.postgres_offsite in
# ../../proxmox/opentofu/postgres.tf) once the B2 keys are in
# proxmox/opentofu/secrets.sops.env: the values arrive as KEY=value lines on
# stdin (never argv, never a file in the repo):
#
#   B2_KEY_ID  B2_APP_KEY  B2_BUCKET  B2_ENDPOINT  B2_REGION  CIPHER_PASS
#
# With nothing on stdin it reuses the config it wrote before, so the operator
# can run it by hand:
#
#   ssh root@10.10.10.12 'pct exec 130 -- bash /root/postgres/offsite.sh --restart-ok' </dev/null
#
# Turning archive_mode on needs a Postgres restart. Without --restart-ok this
# never restarts: it writes the config, proves the bucket (stanza-create), and
# reports the restart as pending. With --restart-ok, and only after
# stanza-create passed, it turns archiving on, restarts, proves the archive
# (pgbackrest check; rolls back and restarts again if that fails), then
# enables the jobs and starts the first full backup. An archive_command that
# keeps failing fills pg_wal, hence the order.
#
# Test-only stdin keys (the local proof against a stand-in S3 server,
# docs/experiments/2026-11-09-pgbackrest-offsite-local.md): S3_URI_STYLE,
# S3_PORT, S3_VERIFY_TLS. Never set for B2.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8

RESTART_OK=0
for a in "$@"; do
  case "$a" in
    --restart-ok) RESTART_OK=1 ;;
    *) echo "usage: offsite.sh [--restart-ok] (KEY=value lines on stdin)" >&2; exit 2 ;;
  esac
done

PG_MAJOR=18
CLUSTER="${PG_MAJOR}-main"
UNIT="postgresql@${CLUSTER}"
CONF=/etc/postgresql/${PG_MAJOR}/main
STANZA=main
SRC=/root/postgres
PGBR_CONF=/etc/pgbackrest/pgbackrest.conf
ARCHIVE_CONF=$CONF/conf.d/offsite.conf

as_pg() { runuser -u postgres -- "$@"; }
psql_val() { as_pg psql -XAtc "$1"; }
pgbr() { as_pg pgbackrest --stanza="$STANZA" "$@"; }

# --- secrets from stdin (optional) --------------------------------------------
declare -A V=()
if [ ! -t 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && V[${line%%=*}]=${line#*=}
  done
fi

# --- package --------------------------------------------------------------------
# From PGDG (sources written by setup.sh): the same repo as the server.
# jq reads pgBackRest's JSON in the jobs (offsite-job.sh).
if ! command -v pgbackrest >/dev/null || ! command -v jq >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends pgbackrest jq
fi

# --- config ------------------------------------------------------------------------
if [ "${#V[@]}" -gt 0 ]; then
  for k in B2_KEY_ID B2_APP_KEY B2_BUCKET B2_ENDPOINT B2_REGION CIPHER_PASS; do
    [ -n "${V[$k]:-}" ] || { echo "offsite: missing $k on stdin" >&2; exit 1; }
  done
  [[ ${V[B2_BUCKET]} =~ ^[a-z0-9][a-z0-9-]{4,61}[a-z0-9]$ ]] || { echo "offsite: B2_BUCKET is not a bucket name" >&2; exit 1; }
  [[ ${V[B2_ENDPOINT]} =~ ^[a-z0-9.-]+$ ]] || { echo "offsite: B2_ENDPOINT is a host name, without https://" >&2; exit 1; }
  [[ ${V[B2_REGION]} =~ ^[a-z0-9-]+$ ]] || { echo "offsite: B2_REGION looks wrong" >&2; exit 1; }
  [ "${#V[CIPHER_PASS]}" -ge 32 ] || { echo "offsite: CIPHER_PASS is shorter than 32 characters" >&2; exit 1; }

  install -d -m 0750 -o root -g postgres /etc/pgbackrest
  tmp=$(mktemp /etc/pgbackrest/.pgbackrest.conf.XXXXXX)
  {
    echo "# managed by services/postgres/offsite.sh — holds the B2 key and the cipher passphrase."
    echo "[global]"
    echo "repo1-type=s3"
    echo "repo1-path=/pgbackrest"
    echo "repo1-s3-bucket=${V[B2_BUCKET]}"
    echo "repo1-s3-endpoint=${V[B2_ENDPOINT]}"
    echo "repo1-s3-region=${V[B2_REGION]}"
    echo "repo1-s3-key=${V[B2_KEY_ID]}"
    echo "repo1-s3-key-secret=${V[B2_APP_KEY]}"
    [ -n "${V[S3_URI_STYLE]:-}" ] && echo "repo1-s3-uri-style=${V[S3_URI_STYLE]}"
    [ -n "${V[S3_PORT]:-}" ] && echo "repo1-storage-port=${V[S3_PORT]}"
    [ -n "${V[S3_VERIFY_TLS]:-}" ] && echo "repo1-storage-verify-tls=${V[S3_VERIFY_TLS]}"
    # Encrypted in the CT: B2 only ever holds ciphertext. The passphrase is
    # in SOPS; without it the bucket is unreadable (secrets.md).
    echo "repo1-cipher-type=aes-256-cbc"
    echo "repo1-cipher-pass=${V[CIPHER_PASS]}"
    # Two fulls, one every 3 days: a 3-6 day restore window; WAL is kept
    # from the oldest full on (retention-archive follows). PBS keeps the
    # older history at home. The 10 GB free tier is guarded by pg-offsite.
    echo "repo1-retention-full=2"
    # Small files in bundles: far fewer objects, so fewer B2 list/get calls.
    echo "repo1-bundle=y"
    echo "compress-type=zst"
    echo "process-max=2"
    echo "start-fast=y"
    # Async archiving: archive_command returns once the segment is in the
    # bucket, several segments are pushed per connection. If the bucket
    # stays unreachable, WAL waiting in pg_wal is dropped past 4 GiB rather
    # than filling the 20 GB disk: the database stays up, the off-site copy
    # gets a gap that the next full closes (the archive alert fires long
    # before, at 1 h).
    echo "archive-async=y"
    echo "spool-path=/var/spool/pgbackrest"
    echo "archive-push-queue-max=4GiB"
    # No log files of its own (observability standard §2): the console
    # output goes to the journal of whichever unit runs it.
    echo "log-level-console=info"
    echo "log-level-stderr=warn"
    echo "log-level-file=off"
    echo
    echo "[${STANZA}]"
    echo "pg1-path=/var/lib/postgresql/${PG_MAJOR}/main"
    echo "pg1-socket-path=/run/postgresql"
  } > "$tmp"
  chown root:postgres "$tmp"
  chmod 0640 "$tmp"
  mv "$tmp" "$PGBR_CONF"
elif [ ! -s "$PGBR_CONF" ]; then
  echo "offsite: no secrets on stdin and no $PGBR_CONF yet: run it through tofu apply first" >&2
  exit 1
fi
install -d -m 0750 -o postgres -g postgres /var/spool/pgbackrest

# --- the jobs ------------------------------------------------------------------------
install -m 0755 "$SRC/offsite-job.sh" /usr/local/sbin/pg-offsite
install -d -m 0700 /var/lib/pg-offsite
cat > /etc/systemd/system/pg-offsite-metrics.service <<'UNIT'
# managed by services/postgres/offsite.sh
[Unit]
Description=Off-site archive freshness → node_exporter textfile (services/postgres)
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pg-offsite metrics
UNIT
cat > /etc/systemd/system/pg-offsite-metrics.timer <<'UNIT'
# managed by services/postgres/offsite.sh
[Unit]
Description=Off-site archive freshness every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/pg-offsite-daily.service <<'UNIT'
# managed by services/postgres/offsite.sh
[Unit]
Description=Off-site full backup when due, repo size and the 10 GB guard (services/postgres)
After=postgresql.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pg-offsite daily
TimeoutStartSec=6h
Nice=10
IOSchedulingClass=idle
UNIT
# 04:00 WIB: after the 01:30 dump and the 02:30 PBS backup.
cat > /etc/systemd/system/pg-offsite-daily.timer <<'UNIT'
# managed by services/postgres/offsite.sh
[Unit]
Description=Daily off-site check; a full backup every third day

[Timer]
OnCalendar=*-*-* 04:00:00 Asia/Jakarta
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload

# --- prove the bucket before anything depends on it ---------------------------------
# stanza-create writes archive.info and backup.info (encrypted) into the bucket
# and reads them back: key, bucket, endpoint and passphrase are all right.
# Re-running it on an existing, matching stanza is a no-op.
if ! pgbr stanza-create; then
  echo "offsite: stanza-create failed: archive_mode stays off (fix the bucket or key, then re-run)" >&2
  exit 1
fi

archive_live=$(psql_val "SHOW archive_mode")
archive_conf() {
  cat > "$ARCHIVE_CONF" <<EOF
# managed by services/postgres/offsite.sh (ADR 0034) — written only after
# pgbackrest stanza-create passed.
archive_mode = on
archive_command = 'pgbackrest --stanza=${STANZA} archive-push %p'
# A segment is switched (and shipped) at least every 15 min while anything
# is written: at most ~15 min of commits lost if the house is.
archive_timeout = 15min
EOF
  chown postgres:postgres "$ARCHIVE_CONF"
}
wait_ready() {
  for _ in $(seq 1 60); do as_pg pg_isready -q && return 0; sleep 1; done
  as_pg pg_isready -q
}

if [ "$archive_live" = on ]; then
  archive_conf
  systemctl reload "$UNIT"
elif [ "$RESTART_OK" = 1 ]; then
  archive_conf
  echo "offsite: restarting PostgreSQL to turn archive_mode on (--restart-ok)"
  systemctl restart "$UNIT"
  wait_ready
  [ "$(psql_val "SHOW archive_mode")" = on ] || { echo "offsite: archive_mode still off after the restart" >&2; exit 1; }
else
  # A config file left from an earlier run must not turn archiving on at
  # some unplanned restart: the restart is the operator's call.
  rm -f "$ARCHIVE_CONF"
  echo "offsite: bucket OK (stanza ${STANZA}); PENDING: archive_mode needs a PostgreSQL restart."
  echo "offsite: in an approved window run: pct exec 130 -- bash /root/postgres/offsite.sh --restart-ok"
  exit 0
fi

# --- prove the archive: a forced WAL switch must arrive in the bucket ----------------
if ! pgbr check; then
  echo "offsite: pgbackrest check failed: archiving is not working" >&2
  if [ "$archive_live" != on ]; then
    echo "offsite: rolling back: archive_mode off, restarting again" >&2
    rm -f "$ARCHIVE_CONF"
    systemctl restart "$UNIT"
    wait_ready
  fi
  exit 1
fi

systemctl enable -q --now pg-offsite-metrics.timer pg-offsite-daily.timer
/usr/local/sbin/pg-offsite metrics
# The first full backup right away, in the background (an upload of the
# whole cluster): the daily job runs one whenever none is younger than 3 days.
info=$(pgbr info --output=json)
if [ "$(jq '[.[0].backup[]? | select(.type == "full")] | length' <<<"$info")" = 0 ]; then
  systemctl start --no-block pg-offsite-daily.service
  echo "offsite: first full backup started (journalctl -u pg-offsite-daily -f)"
fi
echo "offsite: archiving to the bucket is live (archive_timeout 15min, stanza ${STANZA})"
