#!/usr/bin/env bash
# postgres: read-only access to an app's database for people (ADR 0029).
#
# Run by OpenTofu (terraform_data.postgres_readers in postgres.tf) like
# roles.sh: ssh root@pve2 (pinned host key) -> pct exec 130 -> this script.
#
#   readers.sh <db>=<table.column>,<table.column>... ...   one argument per database
#   stdin: `<db> <login> <password>`, one line per person
#
# Per database, a NOLOGIN group `<db>_read`: CONNECT, USAGE on `public`, and
# SELECT on every column of every table there except the hidden ones
# (credentials, and anything else that grants access). Grants are by column,
# never by table and never by default privileges, so it fails closed: a table
# or column that a migration adds later is unreadable until this runs again,
# after someone has checked it for secrets (services/larasrouter/README.md).
# `SELECT *` works on a table whose columns are all granted.
#
# Per person, a login role `<db>_<handle>` in that group. The grants are the
# control. The role's settings (read-only transactions, short timeouts, few
# connections) are a seatbelt the person could SET away: CT 130 is shared, and
# a transaction left open would hold back vacuum and stall a migration's
# ALTER TABLE.
#
# A login still in a `*_read` group but no longer declared loses LOGIN and its
# sessions. Nothing is ever dropped.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

psql_su() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"; }
name_re='^[a-z][a-z0-9_]{0,62}$'
col_re='^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$'

read_groups=()
for arg in "$@"; do
  db=${arg%%=*} hidden=${arg#*=}
  [[ $db =~ $name_re ]] || { echo "readers: bad database '${db}'" >&2; exit 1; }
  grp="${db}_read"
  # A typo in the hidden list must not quietly grant the column it meant.
  cols=$(runuser -u postgres -- psql -XAt -d "$db" -c \
    "SELECT table_name || '.' || column_name FROM information_schema.columns WHERE table_schema = 'public'")
  for h in ${hidden//,/ }; do
    [[ $h =~ $col_re ]] || { echo "readers: bad hidden column '${h}'" >&2; exit 1; }
    grep -qxF "$h" <<<"$cols" || { echo "readers: ${db}: hidden column ${h} does not exist" >&2; exit 1; }
  done
  # One transaction: the group never sees every grant revoked, nor a hidden
  # column granted. Revoking a table's privileges revokes its column ones too,
  # and the default privilege an earlier version of this script set goes.
  psql_su -d "$db" -v db="$db" -v grp="$grp" -v hidden="$hidden" <<'SQL'
SELECT format('CREATE ROLE %I NOLOGIN', :'grp') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'grp') \gexec
BEGIN;
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'grp') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'grp') \gexec
SELECT format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', :'grp') \gexec
SELECT format('GRANT SELECT (%s) ON public.%I TO %I',
         string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) FILTER (WHERE NOT hidden),
         table_name, :'grp')
  FROM (SELECT c.table_name, c.column_name, c.ordinal_position,
               c.table_name || '.' || c.column_name = ANY (string_to_array(:'hidden', ',')) AS hidden
          FROM information_schema.columns c
          JOIN pg_tables t ON t.schemaname = c.table_schema AND t.tablename = c.table_name
         WHERE c.table_schema = 'public') AS x
 GROUP BY table_name
HAVING NOT bool_and(hidden) \gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON TABLES FROM %I', :'db', :'grp') \gexec
COMMIT;
SQL
  read_groups+=("$grp")
done

declared=()
while read -r db login READER_PASSWORD; do
  [ -n "${db:-}" ] || continue
  grp="${db}_read"
  [[ " ${read_groups[*]} " == *" ${grp} "* ]] || { echo "readers: ${login}: no readers group for ${db} (not an argument)" >&2; exit 1; }
  [[ $login =~ $name_re && $login == "${db}_"* && $login != *_read ]] || { echo "readers: bad login '${login}' (must be ${db}_<handle>)" >&2; exit 1; }
  [ "${#READER_PASSWORD}" -ge 24 ] || { echo "readers: password for ${login} is too short" >&2; exit 1; }
  # Never take over a role that is not already a reader of this database (an
  # app's own role above all: this sets the password).
  state=$(runuser -u postgres -- psql -XAt -c "SELECT CASE
      WHEN NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${login}') THEN 'new'
      WHEN EXISTS (SELECT FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member JOIN pg_roles g ON g.oid = m.roleid
                    WHERE r.rolname = '${login}' AND g.rolname = '${grp}') THEN 'reader'
      ELSE 'other' END")
  [ "$state" != other ] || { echo "readers: ${login} exists and is not a reader of ${db}; refusing" >&2; exit 1; }
  export READER_PASSWORD
  # As in roles.sh: the password reaches psql through the environment, and
  # statements in this session are never logged.
  psql_su -v login="$login" -v grp="$grp" <<'SQL'
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
\getenv pw READER_PASSWORD
SELECT format('CREATE ROLE %I LOGIN IN ROLE %I', :'login', :'grp') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'login') \gexec
SELECT format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5 PASSWORD %L', :'login', :'pw') \gexec
SELECT format('ALTER ROLE %I SET default_transaction_read_only = on', :'login') \gexec
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'login', '60s') \gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'login', '60s') \gexec
SQL
  unset READER_PASSWORD
  declared+=("$login")
done

stale=$(runuser -u postgres -- psql -XAt -c "SELECT r.rolname FROM pg_roles r
    JOIN pg_auth_members m ON m.member = r.oid JOIN pg_roles g ON g.oid = m.roleid
   WHERE g.rolname LIKE '%\_read' AND r.rolcanlogin
     AND r.rolname <> ALL (string_to_array('${declared[*]}', ' '))")
for login in $stale; do
  psql_su -v login="$login" <<'SQL'
SELECT format('ALTER ROLE %I NOLOGIN', :'login') \gexec
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = :'login' \g /dev/null
SQL
  echo "readers: ${login} is no longer declared: login disabled, sessions ended"
done

echo "readers: ${#read_groups[@]} group(s)${read_groups[*]:+: ${read_groups[*]}}; ${#declared[@]} reader(s)${declared[*]:+: ${declared[*]}}"
