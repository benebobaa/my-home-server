#!/usr/bin/env bash
# Kubeletto's database migrations (goose) against the HOME copy in CT 130 —
# never production (Kubeletto's own scripts/db-migrate.sh targets prod).
#
# goose runs inside CT 130 and connects to the LAN address over TLS as the
# app role `kubeletto` (pg_hba admits it from the servers VLAN), so every
# object stays owned by the app role. The DSN reaches goose in GOOSE_DBSTRING
# through the guest's stdin, never argv.
#
#   ./migrate.sh [status|up|version]     (default: status)
#   KUBELETTO_REPO=~/Documents/benelabs/kubeletto-home   (migrations source)
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(git rev-parse --show-toplevel)

CMD=${1:-status}
case "$CMD" in status|up|version) ;; *) echo "usage: $0 [status|up|version]" >&2; exit 2 ;; esac
KUBELETTO_REPO=${KUBELETTO_REPO:-$HOME/Documents/benelabs/kubeletto-home}
MIGRATIONS="$KUBELETTO_REPO/apps/core/internal/db/migrations"
GOOSE_VERSION=v3.28.0
NODE=root@10.10.10.12
CT=130
[ -d "$MIGRATIONS" ] || { echo "no migrations at $MIGRATIONS" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A static linux/amd64 goose; cross-built installs land in GOPATH/bin/linux_amd64.
env -u GOBIN GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go install "github.com/pressly/goose/v3/cmd/goose@${GOOSE_VERSION}"
bin="$(go env GOPATH)/bin/linux_amd64/goose"
[ -x "$bin" ] || { echo "goose build failed" >&2; exit 1; }
(cd "$MIGRATIONS" && find . -maxdepth 1 -name "*.sql" -print0 | COPYFILE_DISABLE=1 tar --no-xattrs -cf "$work/migrations.tar" --null -T -)

PW=$(cd "$REPO/proxmox/opentofu" &&
  echo 'nonsensitive(random_password.postgres["kubeletto"].result)' |
  sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tr -d '"')
[ ${#PW} -ge 20 ] || { echo "no kubeletto DB password from tofu" >&2; exit 1; }
PG_IP=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["hosts"]["postgres"]["ip"])' "$REPO/inventory/lab.yaml")

ssh -o BatchMode=yes "$NODE" "install -d -m 700 /var/tmp/kmig-$$"
scp -q -o BatchMode=yes "$bin" "$work/migrations.tar" "$NODE:/var/tmp/kmig-$$/"
ssh -o BatchMode=yes "$NODE" "pct exec $CT -- install -d -m 700 /root/kmig &&
  pct push $CT /var/tmp/kmig-$$/goose /root/kmig/goose --perms 0700 &&
  pct push $CT /var/tmp/kmig-$$/migrations.tar /root/kmig/migrations.tar &&
  rm -rf /var/tmp/kmig-$$"

{
  printf 'export GOOSE_DRIVER=postgres\n'
  printf "export GOOSE_DBSTRING='postgresql://kubeletto:%s@%s:5432/kubeletto?sslmode=require'\n" \
    "$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$PW")" "$PG_IP"
  cat <<EOF
set -euo pipefail
cd /root/kmig && rm -rf m && mkdir m && tar -C m -xf migrations.tar
./goose -dir m $CMD
rc=\$?
cd / && rm -rf /root/kmig
exit \$rc
EOF
} | ssh -o BatchMode=yes "$NODE" "pct exec $CT -- bash -s"
