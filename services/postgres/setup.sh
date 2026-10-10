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
# Arguments (from inventory/lab.yaml): this host's IP, and the CIDR apps
# connect from.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Whatever locale the caller's SSH session carries (the operator's Mac sends
# en_US.UTF-8, which the container does not have) must not leak in.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

LISTEN_IP=${1:?usage: setup.sh <listen-ip> <app-cidr>}
APP_CIDR=${2:?usage: setup.sh <listen-ip> <app-cidr>}

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
# (observability standard §2). Statements are never logged in full: they can
# carry secrets. Slow ones are, by duration.
log_destination = 'syslog'
syslog_ident = 'postgres'
log_line_prefix = 'user=%u db=%d app=%a client=%h '
log_statement = 'none'
log_min_duration_statement = 1s
log_lock_waits = on
log_temp_files = 64MB
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
chown postgres:postgres "$CONF/conf.d/homelab.conf" "$CONF/pg_hba.conf"
chmod 0640 "$CONF/pg_hba.conf"

systemctl enable -q "postgresql@${PG_MAJOR}-main"
systemctl restart "postgresql@${PG_MAJOR}-main"
for _ in $(seq 1 30); do
  runuser -u postgres -- pg_isready -q && break
  sleep 1
done
runuser -u postgres -- pg_isready -q

psql_admin() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# --- exporter: role `prometheus` over the unix socket, peer auth, no password ------
psql_admin <<'SQL'
SELECT 'CREATE ROLE prometheus LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'prometheus') \gexec
GRANT pg_monitor TO prometheus;
SQL
cat > /etc/default/prometheus-postgres-exporter <<'EOF'
# managed by services/postgres/setup.sh
DATA_SOURCE_NAME='host=/run/postgresql user=prometheus dbname=postgres sslmode=disable'
ARGS='--web.listen-address=:9187'
EOF
systemctl enable -q prometheus-postgres-exporter
systemctl restart prometheus-postgres-exporter

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
for _ in $(seq 1 15); do
  curl -fsS http://127.0.0.1:9187/metrics 2>/dev/null | grep -q '^pg_up 1' && break
  sleep 1
done
curl -fsS http://127.0.0.1:9187/metrics | grep -q '^pg_up 1' \
  || { echo "postgres: exporter does not report pg_up 1" >&2; exit 1; }
enc=$(runuser -u postgres -- psql -XAtc "SELECT pg_encoding_to_char(encoding) || ' ' || datlocprovider::text || ' ' || coalesce(datlocale, datcollate) FROM pg_database WHERE datname = 'template1'")
[ "$enc" = "UTF8 b C.UTF-8" ] || { echo "postgres: cluster is '${enc}', expected 'UTF8 b C.UTF-8' (rebuild the CT: README)" >&2; exit 1; }
echo "postgres setup complete ($(runuser -u postgres -- psql -XAtc 'SHOW server_version'), ${enc})"
