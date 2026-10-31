#!/usr/bin/env bash
# The kubeletto database role's password, for a GUI client on the Mac. It comes
# from OpenTofu state and goes to the clipboard only; nothing is printed:
#
#   ./db-password.sh | pbcopy
#
# The tunnel is services/larasrouter/tunnel.py (it relays to the shared Postgres
# and does not pick a database). Start it with `python3 ../larasrouter/tunnel.py db`
# and connect a GUI client to host 127.0.0.1, port 15432, database and user
# kubeletto, sslmode=require (the server certificate is self-signed, so it is
# encrypted but not verified; see services/postgres/README.md).
set -euo pipefail
cd "$(dirname "$0")/../../proxmox/opentofu"
tf() { echo "$1" | sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tail -n1 | tr -d '"\n'; }
printf '%s' "$(tf 'nonsensitive(random_password.postgres["kubeletto"].result)')"
