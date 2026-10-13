#!/usr/bin/env bash
# Re-create tenant workloads on the home cluster from the database (a cutover
# step; the tool is Kubeletto's apps/core/cmd/restore-services). The home
# cluster is built new, so no tenant app exists there until something deploys
# it: for each Knative service that ran on the rented server, the tool redeploys
# the service's latest ready revision (the stored image, no rebuild) through the
# normal pipeline; suspended tenants are skipped. A home core in worker mode
# does the deploying.
#
#   ./restore.sh list                 capture `namespace name` of prod's Knative
#                                     services (read-only) into a private file
#   ./restore.sh run [flags]          DRY RUN against the home database
#   ./restore.sh run --apply [flags]  write the deployments
#
# The list lives in ~/.cache/kubeletto-restore (0700), apart from dbcopy.sh's dump.
#
# flags (passed through): --apply, -pace 5s, -max 100,
#   -only-tenants a1b2c3d4,...   a rehearsal sample (8-character tenant prefixes)
#   -skip-tenants a1b2c3d4,...
#
# KUBELETTO_DB=kubeletto_next ./restore.sh run   targets a scratch copy instead.
# The list is the truth, not the database's status columns: the home core
# rewrites those to Idled when a service is missing. Capture it while prod is
# frozen. Staging follows migrate.sh: never a predictable path in a
# world-writable directory (what lands runs as postgres).
set -euo pipefail
umask 077
cd "$(dirname "$0")"

PROD=${KUBELETTO_PROD_SSH:-root@103.59.160.198}
NODE=root@10.10.10.12
CT=130
DB=${KUBELETTO_DB:-kubeletto}
[[ $DB =~ ^[a-z_][a-z0-9_]{0,40}$ ]] || { echo "bad KUBELETTO_DB" >&2; exit 2; }
KUBELETTO_REPO=${KUBELETTO_REPO:-$HOME/Documents/benelabs/kubeletto-home}
# Its own directory, NOT dbcopy.sh'"'"'s: `dbcopy.sh dump` wipes its cache directory, and the
# list is captured first (cutover step 0), before the dump (step 2). The first
# dress rehearsal (2026-10-14) lost the list exactly that way.
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/kubeletto-restore
LIST=$CACHE/ksvc.txt
work=''
trap '[ -z "$work" ] || rm -rf "$work"' EXIT

cmd_list() {
  mkdir -p "$CACHE"
  # Tenant services only (kl-* namespaces); the canary and platform probes are not tenants.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROD" \
    "timeout 60 kubectl get ksvc -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null" |
    awk '$1 ~ /^kl-/ {print $1, $2}' | sort > "$LIST.tmp"
  [ -s "$LIST.tmp" ] || { rm -f "$LIST.tmp"; echo "no tenant Knative services listed on prod" >&2; exit 1; }
  mv "$LIST.tmp" "$LIST"
  echo "listed $(wc -l < "$LIST" | tr -d ' ') tenant services in $(cut -d' ' -f1 "$LIST" | sort -u | wc -l | tr -d ' ') namespaces -> $LIST" >&2
}

cmd_run() {
  [ -s "$LIST" ] || { echo "no list at $LIST (run: $0 list)" >&2; exit 2; }
  local args=()
  for a in "$@"; do
    case "$a" in
      --apply) args+=(-apply) ;;
      *) [[ $a =~ ^-?[-A-Za-z0-9_.,=]+$ ]] || { echo "bad flag: $a" >&2; exit 2; }; args+=("$a") ;;
    esac
  done
  local stage
  work=$(mktemp -d)
  (cd "$KUBELETTO_REPO/apps/core" && env -u GOBIN GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$work/restore-services" ./cmd/restore-services)
  stage=$(ssh -o BatchMode=yes "$NODE" "mktemp -d /var/tmp/krestore.XXXXXXXX")
  [[ $stage =~ ^/var/tmp/krestore\.[A-Za-z0-9]+$ ]] || { echo "bad staging dir on $NODE" >&2; exit 1; }
  scp -q -o BatchMode=yes "$work/restore-services" "$LIST" "$NODE:$stage/"
  ssh -o BatchMode=yes "$NODE" "pct exec $CT -- bash -c 'rm -rf /opt/krestore && install -d -m 755 -o root -g root /opt/krestore' &&
    pct push $CT $stage/restore-services /opt/krestore/restore-services --perms 0755 &&
    pct push $CT $stage/ksvc.txt /opt/krestore/ksvc.txt --perms 0644 &&
    rm -rf $stage"
  # DATABASE_URL: the local socket as postgres with role=kubeletto (pg_hba admits
  # the app role to its own database only), as migrate.sh does for scratch copies.
  printf '%s\n' \
    'trap "rm -rf /opt/krestore" EXIT' \
    "su postgres -s /bin/bash -c \"DATABASE_URL='postgres://postgres@/$DB?host=/var/run/postgresql&options=-c%20role%3Dkubeletto' /opt/krestore/restore-services -list /opt/krestore/ksvc.txt ${args[*]:-}\"" |
    ssh -o BatchMode=yes "$NODE" "pct exec $CT -- bash -s"
}

case "${1:-}" in
  list) cmd_list ;;
  run) shift; cmd_run "$@" ;;
  *) sed -n 2,22p "$0" >&2; exit 2 ;;
esac
