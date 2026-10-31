#!/usr/bin/env bash
# larasrouter's two connection strings for the internal Postgres and Valkey.
# They carry passwords: nothing is printed except the one value asked for, so
# send it straight to the clipboard and paste it into the Kubeletto console:
#
#   ./urls.sh database | pbcopy     # DATABASE_URL
#   ./urls.sh redis | pbcopy        # REDIS_URL
#   ./urls.sh db-password | pbcopy      # just the password, for a GUI client (tunnel.py)
#   ./urls.sh redis-password | pbcopy
#   ./urls.sh reader larasrouter_reader1 | pbcopy        # a person's read-only logins (ADR 0029):
#   ./urls.sh redis-reader larasrouter_reader1 | pbcopy  #   Postgres, Valkey
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
  reader)
    [[ ${2:-} =~ ^larasrouter_[a-z0-9_]+$ ]] || { echo "usage: $0 reader larasrouter_<handle>" >&2; exit 2; }
    printf 'postgres://%s:%s@10.10.20.21:5432/larasrouter?sslmode=require' "$2" \
      "$(tf "nonsensitive(random_password.postgres_reader[\"$2\"].result)")" ;;
  redis-reader)
    [[ ${2:-} =~ ^larasrouter_[a-z0-9_]+$ ]] || { echo "usage: $0 redis-reader larasrouter_<handle>" >&2; exit 2; }
    printf 'rediss://%s:%s@10.10.20.23:6381/0' "$2" \
      "$(tf "nonsensitive(random_password.valkey_reader[\"$2\"].result)")" ;;
  *) echo "usage: $0 database|redis|db-password|redis-password|reader <login>|redis-reader <login> (pipe to pbcopy)" >&2; exit 2 ;;
esac
