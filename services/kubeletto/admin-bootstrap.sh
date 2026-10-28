#!/usr/bin/env bash
# Creates the first admin account on the home cluster (ADR 0027). The
# admin_users table is empty, so nobody can log in to the admin console yet.
#
# Run it yourself, in a terminal. It asks for the email and the password here;
# neither is printed or put on a command line. The values reach VM 300 through
# the guest agent's stdin, then the platform-admin container through kubectl
# exec's stdin, and the core's bootstrap-admin subcommand creates the account.
# If the email already exists, nothing changes.
set -euo pipefail
NODE=root@10.10.10.12
VMID=300

read -r -p "Admin email: " email
read -r -s -p "Admin password (at least 8 characters): " pw; echo
read -r -s -p "Repeat the password: " pw2; echo
[ "$pw" = "$pw2" ] || { echo "the two passwords differ" >&2; exit 1; }
[ "${#pw}" -ge 8 ] || { echo "the password must be at least 8 characters" >&2; exit 1; }
case "$email" in *@*.*) ;; *) echo "that does not look like an email address" >&2; exit 1 ;; esac

{
  # The values are part of the script text, which arrives on stdin.
  printf 'E=%q\nP=%q\n' "$email" "$pw"
  cat <<'REMOTE'
POD=$(kubectl -n platform get pod -l app.kubernetes.io/name=platform-admin -o jsonpath='{.items[0].metadata.name}')
printf '%s\n%s\n' "$E" "$P" | kubectl -n platform exec -i "$POD" -c platform-admin -- \
  sh -c 'read -r E; read -r P; export ADMIN_EMAIL="$E" ADMIN_PASSWORD="$P"; exec /serverless bootstrap-admin'
REMOTE
} | ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout 120 -- bash -s" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
