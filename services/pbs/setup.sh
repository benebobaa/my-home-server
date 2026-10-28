#!/usr/bin/env bash
# pbs in-guest setup: Proxmox Backup Server 4 (Debian 13), one datastore and
# its schedules (ADR 0009). Idempotent.
#
# Run by OpenTofu (terraform_data.pbs_setup in ../../proxmox/opentofu/pbs.tf)
# every time a file in this directory changes: the directory is streamed to
# /root/pbs through the pinned root SSH to pve3 + `pct exec`, then this runs.
# The cluster side (token, storage entry, backup job) is
# proxmox/opentofu/files/pbs-link.sh; Telegram for PBS's own jobs is notify.sh.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Signing keyring from the PBS install docs (Debian 13 / trixie), checked by
# the sha256 they publish. Once the proxmox-archive-keyring package owns the
# file, apt keeps it current and the published hash no longer applies.
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

# PBS_STORE names the datastore (default main; the replica on pve1 uses replica).
STORE=${PBS_STORE:-main}
STORE_PATH=/var/lib/proxmox-backup/datastore/${STORE}
# Retention: 7 daily, 4 weekly, 6 monthly. PBS prunes; PVE keeps all
# (pbs-link.sh sets keep-all on the storage) so there is one source of truth.
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
PVE_USER=pve@pbs

# --- packages ------------------------------------------------------------------
if ! dpkg -s proxmox-archive-keyring >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$KEYRING_URL"
  echo "$KEYRING_SHA256  $tmp" | sha256sum -c --quiet
  install -m 0644 "$tmp" "$KEYRING"
  rm -f "$tmp"
fi

cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
# managed by services/pbs/setup.sh
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: ${KEYRING}
EOF

apt-get update -qq
apt-get install -y -qq proxmox-backup-server
# The package adds the enterprise repo, which needs a subscription: without
# one every `apt update` fails on it.
rm -f /etc/apt/sources.list.d/pbs-enterprise.sources /etc/apt/sources.list.d/pbs-enterprise.list

# --- datastore -----------------------------------------------------------------
pbm() { proxmox-backup-manager "$@"; }
has() { pbm "$1" list --output-format json | python3 -c "import json,sys; sys.exit(0 if any(x.get('$2')=='$3' for x in json.load(sys.stdin)) else 1)"; }

if ! has datastore name "$STORE"; then
  install -d -m 0750 -o backup -g backup "$(dirname "$STORE_PATH")"
  pbm datastore create "$STORE" "$STORE_PATH" --comment "every guest, nightly (managed by services/pbs)"
fi
# GC daily (frees chunks no snapshot references after pruning). Failures go
# through the notification system (notify.sh → Telegram).
pbm datastore update "$STORE" --gc-schedule daily --notification-mode notification-system

# Prune daily; verify weekly what was not verified in the last 30 days.
if has prune-job id "$STORE-daily"; then
  pbm prune-job update "$STORE-daily" --schedule daily "${KEEP[@]}"
else
  pbm prune-job create "$STORE-daily" --store "$STORE" --schedule daily "${KEEP[@]}"
fi
if has verify-job id "$STORE-weekly"; then
  pbm verify-job update "$STORE-weekly" --schedule 'sat 04:00' --ignore-verified true --outdated-after 30
else
  pbm verify-job create "$STORE-weekly" --store "$STORE" --schedule 'sat 04:00' --ignore-verified true --outdated-after 30
fi

# --- the identity the cluster backs up as --------------------------------------
# Its token (pve@pbs!cluster) and ACLs are created by pbs-link.sh, which hands
# the secret straight to the cluster.
has user userid "$PVE_USER" \
  || pbm user create "$PVE_USER" --comment "Proxmox VE cluster homelab (managed by services/pbs)"

systemctl is-active -q proxmox-backup-proxy
echo "pbs setup complete: datastore ${STORE} at ${STORE_PATH}, UI https://$(hostname -I | awk '{print $1}'):8007"
