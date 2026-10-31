#!/usr/bin/env bash
# postgres in-guest setup: PostgreSQL 18 from the PostgreSQL project's apt
# repo (PGDG), its exporter and the nightly logical dump (ADR 0010).
# Idempotent.
#
# Run by OpenTofu (terraform_data.postgres_setup in
# ../../proxmox/opentofu/postgres.tf) every time a file in this directory
# changes: the directory is streamed to /root/postgres through the pinned root
# SSH to pve2 + `pct exec`, then this runs. App databases and roles are
# roles.sh (passwords on stdin, never in this directory).
#
# Arguments (from inventory/lab.yaml): this host's IP, the CIDR apps
# connect from, the monitoring host's IP (the only one that may scrape), and
# optionally clients outside that CIDR as `db=cidr,db=cidr` (each may reach
# only its own database, e.g. Kubeletto's K3s VM in the DMZ), and where
# people with read-only access come from, also `db=cidr,...` (the group
# `<db>_read` to that database only: the admin gateways; readers.sh).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Whatever locale the caller's SSH session carries (the operator's Mac sends
# en_US.UTF-8, which the container does not have) must not leak in.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

usage="usage: setup.sh <listen-ip> <app-cidr> <monitoring-ip> [db=cidr,...] [reader db=cidr,...]"
LISTEN_IP=${1:?$usage}
APP_CIDR=${2:?$usage}
MONITORING_IP=${3:?$usage}
EXTRA_CLIENTS=${4:-}
READER_CLIENTS=${5:-}

# The major version is the pin; minor releases come from the repo (apt
# upgrade: README). A new major is a pg_upgradecluster, never a re-run.
PG_MAJOR=18
CONF=/etc/postgresql/${PG_MAJOR}/main
SRC=/root/postgres

# PGDG signing key (fingerprint B97B 0AFC AA1A 47F0 44F2 44A0 7FCC 7D46 ACCC 4CF8,
# as published on postgresql.org/download/linux/debian), checked by sha256.
KEY=/usr/share/keyrings/pgdg.asc
KEY_URL=https://www.postgresql.org/media/keys/ACCC4CF8.asc
KEY_SHA256=0144068502a1eddd2a0280ede10ef607d1ec592ce819940991203941564e8e76 # gitleaks:allow (public key checksum)

# --- packages ------------------------------------------------------------------
if [ ! -s "$KEY" ]; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$KEY_URL"
  echo "$KEY_SHA256  $tmp" | sha256sum -c --quiet
  install -m 0644 "$tmp" "$KEY"
  rm -f "$tmp"
fi

cat > /etc/apt/sources.list.d/pgdg.sources <<EOF
# managed by services/postgres/setup.sh
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: trixie-pgdg
Components: main
Signed-By: ${KEY}
EOF

apt-get update -qq
# Installing the server creates the cluster ${PG_MAJOR}/main (data checksums
# on by default since 18) with a self-signed certificate (ssl-cert). Its
# encoding and locale are fixed here, before that happens: UTF-8, and
# Postgres's own C.UTF-8 collation (no glibc dependency, so an OS upgrade
# never silently changes sort order and corrupts indexes).
apt-get install -y -qq postgresql-common
install -d /etc/postgresql-common/createcluster.d
cat > /etc/postgresql-common/createcluster.d/homelab.conf <<'EOF'
# managed by services/postgres/setup.sh
initdb_options = '--encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8'
EOF
apt-get install -y -qq "postgresql-${PG_MAJOR}" prometheus-postgres-exporter

# --- server config -----------------------------------------------------------------
# What the server reads only when it starts. If none of it changes, the run
# reloads instead of restarting (below), so pg_hba changes drop no session.
start_inputs() {
  cat "$CONF/conf.d/homelab.conf" "/etc/systemd/system/postgresql@${PG_MAJOR}-main.service.d/wait-for-address.conf" 2>/dev/null | sha256sum
}
start_inputs_before=$(start_inputs)

# conf.d is read last, so this overrides the packaged postgresql.conf.
# Sized for the container: 2 GB (proxmox/opentofu/postgres.tf).
cat > "$CONF/conf.d/homelab.conf" <<EOF
# managed by services/postgres/setup.sh — edit the repo copy, not this file.
listen_addresses = 'localhost,${LISTEN_IP}'
max_connections = 100

shared_buffers = 512MB
effective_cache_size = 1536MB
maintenance_work_mem = 128MB
work_mem = 8MB
wal_compression = lz4
random_page_cost = 1.1            # SSD

password_encryption = scram-sha-256
ssl = on

# Logs go to the journal (shipped to VictoriaLogs), not to a file of their own
# (observability standard §2). No statement text and no bind parameters,
# not even for slow or failing statements: apps' literals can carry secrets
# and personal data, and the log store is readable by anyone who can query
# it. Errors are still logged (the message, without the statement).
log_destination = 'syslog'
syslog_ident = 'postgres'
log_line_prefix = 'user=%u db=%d app=%a client=%h '
log_statement = 'none'
log_min_duration_statement = -1
log_min_error_statement = panic
log_parameter_max_length = 0
log_parameter_max_length_on_error = 0
log_lock_waits = on
log_temp_files = 64MB

# Per-statement timings, to find slow queries without statement logging
# (README). Queries are stored normalised: constants become \$1, \$2.
# Utility statements are not normalised, so they are not tracked at all:
# roles.sh sends ALTER ROLE ... PASSWORD '<literal>' on every run, and with
# track_utility on that text would sit in the view. top = the statements
# apps send, not those inside functions. Loading the module needs a server
# restart, which this script does below.
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = top
pg_stat_statements.track_utility = off
pg_stat_statements.max = 5000
EOF

# Who may connect, from where. Apps: from the servers VLAN only, over TLS, with
# a password, and only to the database named after their role (`sameuser`).
# Everything else is refused (no matching line).
cat > "$CONF/pg_hba.conf" <<EOF
# managed by services/postgres/setup.sh — edit the repo copy, not this file.
# TYPE    DATABASE  USER  ADDRESS        METHOD
local     all       all                  peer
host      all       all   127.0.0.1/32   scram-sha-256
host      all       all   ::1/128        scram-sha-256
hostssl   sameuser  all   ${APP_CIDR}    scram-sha-256
EOF
# Clients outside the apps' VLAN: one exact line each, own database only.
IFS=',' read -ra extra <<< "$EXTRA_CLIENTS"
for e in "${extra[@]}"; do
  db=${e%%=*} cidr=${e#*=}
  [[ $db =~ ^[a-z][a-z0-9_]{0,62}$ && $cidr =~ ^[0-9./]+$ ]] || { echo "postgres: bad extra client '${e}'" >&2; exit 1; }
  printf 'hostssl   %s  %s  %s  scram-sha-256\n' "$db" "$db" "$cidr" >> "$CONF/pg_hba.conf"
done
# People with read-only access (readers.sh, ADR 0029): members of `<db>_read`,
# to that database only, from the admin gateways. Who gets as far as the
# gateways is the tailnet policy's call (network/tailscale/).
IFS=',' read -ra readers <<< "$READER_CLIENTS"
for e in "${readers[@]}"; do
  db=${e%%=*} cidr=${e#*=}
  [[ $db =~ ^[a-z][a-z0-9_]{0,62}$ && $cidr =~ ^[0-9./]+$ ]] || { echo "postgres: bad reader client '${e}'" >&2; exit 1; }
  printf 'hostssl   %s  +%s_read  %s  scram-sha-256\n' "$db" "$db" "$cidr" >> "$CONF/pg_hba.conf"
done
chown postgres:postgres "$CONF/conf.d/homelab.conf" "$CONF/pg_hba.conf"
chmod 0640 "$CONF/pg_hba.conf"

# Start only once the container holds its LAN address. The packaged unit is
# ordered after network.target only, which a CT reaches before eth0 has its
# address: on the 2026-10-11 boot Postgres logged "could not bind IPv4
# address ... Cannot assign requested address" and served localhost alone,
# unreachable from every app, with nothing restarting it.
install -d "/etc/systemd/system/postgresql@${PG_MAJOR}-main.service.d"
cat > "/etc/systemd/system/postgresql@${PG_MAJOR}-main.service.d/wait-for-address.conf" <<EOF
# managed by services/postgres/setup.sh
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do ip -4 -o addr show | grep -q " ${LISTEN_IP}/" && exit 0; sleep 1; done; echo "no ${LISTEN_IP} after 60 s" >&2; exit 1'
EOF
systemctl daemon-reload

systemctl enable -q "postgresql@${PG_MAJOR}-main"
if systemctl is-active -q "postgresql@${PG_MAJOR}-main" && [ "$(start_inputs)" = "$start_inputs_before" ]; then
  systemctl reload "postgresql@${PG_MAJOR}-main"
else
  systemctl restart "postgresql@${PG_MAJOR}-main"
fi
for _ in $(seq 1 30); do
  runuser -u postgres -- pg_isready -q && break
  sleep 1
done
runuser -u postgres -- pg_isready -q
# A pg_hba.conf that does not parse is not applied: the server keeps the old
# rules and only logs it. Fail the run instead.
bad=$(runuser -u postgres -- psql -XAtc "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")
[ "$bad" = 0 ] || { echo "postgres: pg_hba.conf has ${bad} bad line(s), see pg_hba_file_rules; the old rules stay in force" >&2; exit 1; }

# --- exporter: role `prometheus` over the unix socket, peer auth, no password ------
runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE ROLE prometheus LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'prometheus') \gexec
GRANT pg_monitor TO prometheus;
-- The view lives in the database it was created in and shows every
-- database's statements to superusers and pg_read_all_stats (pg_monitor).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
cat > /etc/default/prometheus-postgres-exporter <<'EOF'
# managed by services/postgres/setup.sh
DATA_SOURCE_NAME='host=/run/postgresql user=prometheus dbname=postgres sslmode=disable'
ARGS='--web.listen-address=:9187'
EOF
systemctl enable -q prometheus-postgres-exporter
systemctl restart prometheus-postgres-exporter

# Only the monitoring host may reach the exporter. It has no auth, and its
# /probe endpoint connects to any target it is given (SSRF): without this,
# every host on VLAN 20 could use it. Postgres itself is gated by pg_hba.
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# managed by services/postgres/setup.sh
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iif lo accept
    tcp dport 9187 ip saddr ${MONITORING_IP} accept
    tcp dport 9187 drop
  }
}
EOF
nft -c -f /etc/nftables.conf
systemctl enable -q nftables
systemctl restart nftables

# --- nightly logical dump (01:30 WIB, before the 02:30 PBS backup) -------------------
install -m 0755 "$SRC/dump.sh" /usr/local/sbin/pg-dump-all
install -d -m 0700 -o postgres -g postgres /var/backups/postgres
cat > /etc/systemd/system/pg-dump-all.service <<'UNIT'
# managed by services/postgres/setup.sh
[Unit]
Description=Logical dump of every PostgreSQL database (services/postgres)
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/sbin/pg-dump-all
UNIT
cat > /etc/systemd/system/pg-dump-all.timer <<'UNIT'
# managed by services/postgres/setup.sh
[Unit]
Description=Nightly logical dump of PostgreSQL, before the PBS backup

[Timer]
OnCalendar=*-*-* 01:30:00 Asia/Jakarta
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable -q --now pg-dump-all.timer

# --- checks ----------------------------------------------------------------------
# The exporter reconnects on its own schedule after the server restart above.
# The metrics are read whole before matching: `curl | grep -q` under pipefail
# fails at random, because grep exits at the first match and curl then dies
# of a closed pipe (exit 23). That failed the 2026-10-29 apply with pg_up 1.
pg_up() { local m; m=$(curl -fsS http://127.0.0.1:9187/metrics 2>/dev/null) && grep -q '^pg_up 1' <<<"$m"; }
for _ in $(seq 1 30); do
  pg_up && break
  sleep 1
done
pg_up || { echo "postgres: exporter does not report pg_up 1" >&2; exit 1; }
enc=$(runuser -u postgres -- psql -XAtc "SELECT pg_encoding_to_char(encoding) || ' ' || datlocprovider::text || ' ' || coalesce(datlocale, datcollate) FROM pg_database WHERE datname = 'template1'")
[ "$enc" = "UTF8 b C.UTF-8" ] || { echo "postgres: cluster is '${enc}', expected 'UTF8 b C.UTF-8' (rebuild the CT: README)" >&2; exit 1; }
echo "postgres setup complete ($(runuser -u postgres -- psql -XAtc 'SHOW server_version'), ${enc})"
