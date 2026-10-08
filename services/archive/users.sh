#!/usr/bin/env bash
# archive: (re)create the File Browser users bene + irene, download-only.
#
# Reads BENE_PASSWORD=... / IRENE_PASSWORD=... on stdin. Run by OpenTofu
# (terraform_data.archive_users) as:
#   ssh root@pve2 (pinned host key) -> pct exec 110 -> this script
# so the passwords never cross an SSH hop without host-key verification.
set -euo pipefail

FB_DB=/var/lib/filebrowser/filebrowser.db
PERMS=(--perm.admin=false --perm.create=false --perm.delete=false --perm.download=true
       --perm.execute=false --perm.modify=false --perm.rename=false --perm.share=false
       --hideDotfiles)

declare -A PW
while IFS='=' read -r k v; do
  case "$k" in BENE_PASSWORD) PW[bene]=$v ;; IRENE_PASSWORD) PW[irene]=$v ;; esac
done
[ -n "${PW[bene]:-}" ] && [ -n "${PW[irene]:-}" ] || { echo "missing passwords on stdin" >&2; exit 1; }

fb() { runuser -u filebrowser -- /usr/local/bin/filebrowser -d "$FB_DB" "$@"; }

# BoltDB takes an exclusive lock: the CLI cannot run next to the service.
systemctl stop filebrowser
trap 'systemctl start filebrowser' EXIT

users=$(fb users ls 2>/dev/null | awk 'NR>1 {print $2}')
for u in bene irene; do
  if grep -qx "$u" <<<"$users"; then
    fb users update "$u" --password "${PW[$u]}" "${PERMS[@]}" >/dev/null
  else
    fb users add "$u" "${PW[$u]}" "${PERMS[@]}" >/dev/null
  fi
done
# The default "admin" user from config init must not survive.
if grep -qx admin <<<"$users"; then
  fb users rm admin >/dev/null
fi
echo "archive users: bene, irene (download-only)"
