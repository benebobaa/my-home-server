#!/usr/bin/env bash
# Creates the platform-admin-tailscale Secret (ADR 0027): the auth key the admin
# pod uses to join the operator's tailnet. The key is read from this directory's
# secrets.sops.env (PLATFORM_ADMIN_TS_AUTHKEY), decrypted in memory, and sent to
# VM 300 through the guest agent's stdin. It never touches disk or argv, and the
# script prints only the outcome.
#
# Make the key reusable, ephemeral, pre-authorized and tagged tag:admin in the
# Tailscale admin console (ADR 0027, operator steps).
set -euo pipefail
cd "$(dirname "$0")"
NODE=root@10.10.10.12
VMID=300

key=$(sops decrypt secrets.sops.env | sed -n 's/^PLATFORM_ADMIN_TS_AUTHKEY=//p')
[ -n "$key" ] || { echo "PLATFORM_ADMIN_TS_AUTHKEY is not set in secrets.sops.env" >&2; exit 1; }
case "$key" in tskey-*) ;; *) echo "not a Tailscale auth key (expected tskey-...)" >&2; exit 1 ;; esac

{
  printf "TSKEY='%s'\n" "$key"
  cat <<'REMOTE'
kubectl -n platform create secret generic platform-admin-tailscale \
  --from-literal=authkey="$TSKEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "platform-admin-tailscale applied"
# The node state for tailscaled (--state=kube:): created empty if missing, so a
# restart keeps the node. The pod's role can read and write it, but not create it.
kubectl -n platform create secret generic platform-admin-tailscale-state 2>/dev/null || true
echo "platform-admin-tailscale-state present"
REMOTE
} | ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout 60 -- bash -s" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
