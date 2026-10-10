#!/usr/bin/env bash
# Nightly logical dump of every database (pg-dump-all.timer, 01:30 WIB), into
# /var/backups/postgres/<date>/ on the root disk, so the 02:30 PBS backup
# carries it. Installed as /usr/local/sbin/pg-dump-all by setup.sh; runs as
# `postgres`. PBS keeps the history (7 daily / 4 weekly / 6 monthly): the
# last few nights here are for a quick restore without PBS.
#
#   globals.sql   roles (with password hashes) and their memberships
#   <db>.dump     one per database, custom format: pg_restore -d <db> --clean
set -euo pipefail

DIR=/var/backups/postgres
KEEP=3

out="$DIR/$(date +%F)"
tmp="$out.partial"
rm -rf "$tmp"
install -d -m 0700 "$tmp"

pg_dumpall --globals-only --file="$tmp/globals.sql"
n=0
while IFS= read -r db; do
  pg_dump --format=custom --file="$tmp/$db.dump" "$db"
  n=$((n + 1))
done < <(psql -XAtc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1")

rm -rf "$out"
mv "$tmp" "$out"
find "$DIR" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' | sort | head -n -"$KEEP" | xargs -r rm -rf
echo "pg-dump-all: ${n} database(s) + globals → ${out} ($(du -sh "$out" | cut -f1))"
