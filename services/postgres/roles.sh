#!/usr/bin/env bash
# postgres: one login role + one database per app, both named after the app
# (ADR 0010). Reads `name=password` lines on stdin.
#
# Run by OpenTofu (terraform_data.postgres_roles) as
#   ssh root@pve2 (pinned host key) -> pct exec 130 -> this script
# with the passwords OpenTofu generates (random_password.postgres, encrypted
# state). Every run sets each password again, so a rotated one takes effect.
#
# Never drops anything: a role or database removed from postgres.tf stays
# until it is dropped by hand (README: removing an app's database).
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

declared=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  name=${line%%=*}
  APP_PASSWORD=${line#*=}
  [[ $name =~ ^[a-z][a-z0-9_]{0,62}$ ]] || { echo "roles: bad name '${name}'" >&2; exit 1; }
  [ "${#APP_PASSWORD}" -ge 24 ] || { echo "roles: password for ${name} is too short" >&2; exit 1; }
  export APP_PASSWORD
  # The password reaches psql through the environment (\getenv), not argv,
  # and statements in this session are never logged, not even on error.
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -v name="$name" <<'SQL'
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
\getenv pw APP_PASSWORD
SELECT format('CREATE ROLE %I LOGIN', :'name') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'name') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'name', :'pw') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'name') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'name') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'name') \gexec
SQL
  unset APP_PASSWORD
  declared+=("$name")
done

# Report (never drop) app roles that are no longer declared.
extra=$(runuser -u postgres -- psql -XAtc \
  "SELECT string_agg(rolname, ' ' ORDER BY rolname) FROM pg_roles
    WHERE rolcanlogin AND rolname NOT IN ('postgres', 'prometheus')
      AND rolname <> ALL (string_to_array('${declared[*]}', ' '))")
[ -z "$extra" ] || echo "roles: present but not declared in postgres.tf (left alone): ${extra}"
echo "roles: ${#declared[@]} app database(s) converged${declared[*]:+: ${declared[*]}}"
