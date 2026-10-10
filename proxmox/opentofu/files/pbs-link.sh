#!/usr/bin/env bash
# Root-only PVE step for PBS (run on pve3 by terraform_data.pbs_link): connect
# the cluster to the backup server and schedule the backups (ADR 0009).
#
#   PBS side   token pve@pbs!cluster, role DatastoreBackup on /datastore/main
#              (back up, list, restore its own backups; no delete, no prune)
#   PVE side   storage `pbs` (cluster-wide, /etc/pve/storage.cfg), keep-all:
#              retention is PBS's prune job (services/pbs/setup.sh)
#              backup job `nightly`: every guest except PBS itself, 02:30,
#              snapshot mode, results through the notification system
#
# The token secret is shown only once, at creation. It goes straight from the
# CT into the storage entry (root-only /etc/pve/priv/storage/pbs.pw) and never
# leaves the cluster. If the storage entry is gone, the token is recreated.
# Idempotent. Arguments: the PBS CT's VMID and IP (from inventory/lab.yaml).
set -euo pipefail

CT=${1:?usage: pbs-link.sh <vmid> <ip>}
IP=${2:?usage: pbs-link.sh <vmid> <ip>}
STORE=main
PVE_USER=pve@pbs
TOKEN=cluster
STORAGE=pbs
JOB=nightly

pbm() { pct exec "$CT" -- proxmox-backup-manager "$@"; }

# --- PBS: token + ACLs (a token's rights are its own ACL ∩ its user's) ----------
# The user's ACL now; the token's once the token exists (below).
pbm acl update "/datastore/${STORE}" DatastoreBackup --auth-id "$PVE_USER"

fp=$(pbm cert info | awk -F': ' '/Fingerprint/ {print $2}' | tr -d ' ')
[ -n "$fp" ] || { echo "pbs-link: could not read the PBS certificate fingerprint" >&2; exit 1; }

storage_ok() {
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 \
    && grep -q "fingerprint ${fp}" /etc/pve/storage.cfg
}

if storage_ok && pbm user list-tokens "$PVE_USER" --output-format json | grep -q "\"tokenid\":\"${PVE_USER}!${TOKEN}\""; then
  pbm acl update "/datastore/${STORE}" DatastoreBackup --auth-id "${PVE_USER}!${TOKEN}"
  echo "pbs-link: storage ${STORAGE} present"
else
  pbm user delete-token "$PVE_USER" "$TOKEN" >/dev/null 2>&1 || true
  # Prints `Result: {"tokenid": …, "value": <secret>}` (no --output-format).
  secret=$(pbm user generate-token "$PVE_USER" "$TOKEN" \
           | python3 -c 'import json, sys; print(json.loads(sys.stdin.read().split("Result:", 1)[1])["value"])')
  pbm acl update "/datastore/${STORE}" DatastoreBackup --auth-id "${PVE_USER}!${TOKEN}"
  args=(--server "$IP" --datastore "$STORE" --username "${PVE_USER}!${TOKEN}"
        --password "$secret" --fingerprint "$fp")
  if pvesm status --storage "$STORAGE" >/dev/null 2>&1; then
    pvesm set "$STORAGE" "${args[@]}"
  else
    pvesm add pbs "$STORAGE" "${args[@]}" --content backup --prune-backups keep-all=1
  fi
  echo "pbs-link: token (re)created, storage ${STORAGE} → ${IP}:${STORE}"
fi
pvesm status --storage "$STORAGE" | grep -q " active " \
  || { echo "pbs-link: storage ${STORAGE} is not active" >&2; exit 1; }

# --- the nightly backup job ---------------------------------------------------------
job=(--schedule '02:30' --storage "$STORAGE" --all 1 --exclude "$CT" --mode snapshot
     --enabled 1 --notification-mode notification-system --notes-template '{{guestname}}'
     --comment "every guest except PBS itself (managed by OpenTofu: proxmox/opentofu/pbs.tf)")
if pvesh get "/cluster/backup/${JOB}" >/dev/null 2>&1; then
  pvesh set "/cluster/backup/${JOB}" "${job[@]}"
else
  pvesh create /cluster/backup --id "$JOB" "${job[@]}"
fi
echo "pbs-link: backup job ${JOB} (02:30, all guests except ${CT})"
