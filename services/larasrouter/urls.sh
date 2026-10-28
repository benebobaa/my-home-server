#!/usr/bin/env bash
# larasrouter's two connection strings for the internal Postgres and Valkey.
# They carry passwords: nothing is printed except the one value asked for, so
# send it straight to the clipboard and paste it into the Kubeletto console:
#
#   ./urls.sh database | pbcopy     # DATABASE_URL
#   ./urls.sh redis | pbcopy        # REDIS_URL
#   ./urls.sh db-password | pbcopy      # just the password, for a GUI client (tunnel.py)
#   ./urls.sh redis-password | pbcopy
#
# Addresses, not names: the DMZ does not resolve home.arpa. sslmode=require and
# skip_verify encrypt but do not verify the server's certificate; larasrouter's
# Redis client takes no CA bundle (a REDIS_TLS_CA option would pin it, ADR 0017).
set -euo pipefail
cd "$(dirname "$0")/../../proxmox/opentofu"
tf() { echo "$1" | sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tail -n1 | tr -d '"\n'; }
case "${1:-}" in
  database) printf 'postgres://larasrouter:%s@10.10.20.21:5432/larasrouter?sslmode=require' \
    "$(tf 'nonsensitive(random_password.postgres["larasrouter"].result)')" ;;
  redis) printf 'rediss://:%s@10.10.20.23:6381/0?skip_verify=true' \
    "$(tf 'nonsensitive(random_password.valkey["larasrouter"].result)')" ;;
  db-password) printf '%s' "$(tf 'nonsensitive(random_password.postgres["larasrouter"].result)')" ;;
  redis-password) printf '%s' "$(tf 'nonsensitive(random_password.valkey["larasrouter"].result)')" ;;
  *) echo "usage: $0 database|redis|db-password|redis-password (pipe to pbcopy)" >&2; exit 2 ;;
esac
