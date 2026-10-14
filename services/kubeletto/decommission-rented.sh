#!/usr/bin/env bash
# Wipe Kubeletto's rented server before its lease ends (2026-11-05):
# docs/runbooks/kubeletto-cutover.md, "Decommissioning the rented server".
#
# It ran production, so it holds K3s with every platform secret, the
# operator's working files in /root (kubeconfig, Infisical and registry
# logins, a database password file, old database dumps) and checkouts in
# /opt. The wipe ENDS THE ROLLBACK and cannot be undone.
#
#   ./decommission-rented.sh            dry run: what is there, nothing changes
#   CONFIRM=wipe-rented-server ./decommission-rented.sh --apply
#
# --apply refuses while any of the three flipped DNS records still points at
# the server (network/cloudflare/flip.sh forward must say "already there"
# three times). It keeps /root/.ssh, .bashrc and .profile, so the server
# stays reachable until the provider takes it back. A wipe of a rented disk
# is best effort (provider snapshots, SSD wear levelling): rotate the shared
# credentials afterwards (the runbook lists them).
set -euo pipefail
cd "$(dirname "$0")"

PROD=${KUBELETTO_PROD_SSH:-root@103.59.160.198}
MODE=${1:-check}
[[ $MODE =~ ^(check|--apply)$ ]] || { sed -n 2,19p "$0" >&2; exit 2; }

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROD" 'bash -s'; }

# What is there: names, counts and sizes only, never contents.
remote <<'CHECK'
echo "host $(hostname), up $(uptime -p)"
echo "k3s: $(k3s --version 2>/dev/null | head -1 || echo 'not installed')"
echo "  Secrets: $(kubectl get secrets -A --no-headers 2>/dev/null | wc -l), tenant namespaces: $(kubectl get ns --no-headers 2>/dev/null | grep -c '^kl-')"
echo "tailscale: $(tailscale status --self --peers=false 2>/dev/null | head -1 | awk '{print $2, $3}' || echo 'not running')"
echo "/root (kept: .ssh .bashrc .profile):"
find /root -mindepth 1 -maxdepth 1 ! -name .ssh ! -name .bashrc ! -name .profile -printf '  %f\n' | sort
echo "/opt: $(ls /opt 2>/dev/null | tr '\n' ' ')"
df -h / | tail -1
CHECK

[ "$MODE" = --apply ] || { echo "dry run: nothing changed (CONFIRM=wipe-rented-server $0 --apply)"; exit 0; }
[ "${CONFIRM:-}" = wipe-rented-server ] || { echo "refusing: set CONFIRM=wipe-rented-server" >&2; exit 2; }

already=$(../../network/cloudflare/flip.sh forward 2>&1 | grep -c '\[already there\]' || true)
[ "$already" = 3 ] || { echo "refusing: flip.sh forward does not show all three records at home ($already/3)" >&2; exit 1; }

remote <<'APPLY'
set -u
echo "== tailscale: log out (the node leaves its tailnet) and stop"
tailscale logout 2>/dev/null || true
systemctl disable --now tailscaled 2>/dev/null || true
rm -rf /var/lib/tailscale
echo "== k3s: uninstall (stops every pod, removes its data and config)"
[ -x /usr/local/bin/k3s-uninstall.sh ] && /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
rm -rf /var/lib/rancher /etc/rancher /var/lib/kubelet /opt/containerd /opt/kubeletto /opt/kubeletto-e2e-build-fixtures
echo "== /root: everything but .ssh .bashrc .profile"
find /root -mindepth 1 -maxdepth 1 ! -name .ssh ! -name .bashrc ! -name .profile -exec rm -rf {} +
echo "== journal"
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
echo "== overwrite the freed space with zeros (best effort; minutes)"
dd if=/dev/zero of=/var/tmp/wipe.zero bs=4M status=none 2>/dev/null || true
sync
rm -f /var/tmp/wipe.zero
echo "== done"
df -h / | tail -1
ls -A /root
APPLY
echo "wiped. Next: rotate the shared credentials (runbook), delete the OpenObserve buckets in R2, remove flip.sh back and the kubeletto-prod SSH alias."
