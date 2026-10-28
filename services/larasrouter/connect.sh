#!/usr/bin/env bash
# Open psql or valkey-cli on larasrouter's data from the operator Mac.
# The Mac cannot reach 10.10.20.x:5432/6381 directly (the pinholes are for the K3s
# worker only), so the client runs INSIDE the container, through the node:
#
#   ./connect.sh db [psql args]       psql as role larasrouter on database larasrouter
#   ./connect.sh redis [valkey-cli args]   valkey-cli on larasrouter's instance (port 6381)
#
#   ./connect.sh db -c 'select count(*) from api_keys'
#   ./connect.sh redis dbsize
#
# The password is read from OpenTofu state and goes into the command line on the
# node for the length of the session (root-only host); it is never printed.
set -euo pipefail
cd "$(dirname "$0")/../../proxmox/opentofu"
tf() { echo "$1" | sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tr -d '"\n'; }
what=${1:-}; shift || true
args=$(printf ' %q' "$@")
case "$what" in
  db)
    PW=$(tf 'nonsensitive(random_password.postgres["larasrouter"].result)')
    ssh -t -o BatchMode=yes root@10.10.10.12 "pct exec 130 -- env PGPASSWORD='$PW' psql 'host=10.10.20.21 dbname=larasrouter user=larasrouter sslmode=require'$args" ;;
  redis)
    PW=$(tf 'nonsensitive(random_password.valkey["larasrouter"].result)')
    ssh -t -o BatchMode=yes root@10.10.10.13 "pct exec 132 -- env REDISCLI_AUTH='$PW' valkey-cli --tls --insecure -h 10.10.20.23 -p 6381$args" ;;
  *) sed -n 2,13p "$0" >&2; exit 2 ;;
esac
