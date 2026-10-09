#!/usr/bin/env bash
# Root-only PVE step for the monitoring CT (run on pve2 by
# terraform_data.monitoring_pve_token): a read-only API identity for
# prometheus-pve-exporter.
#
#   user  prometheus@pve, role PVEAuditor on /   (the OpenTofu token is
#         PVEAdmin, which lacks Permissions.Modify — hence root over SSH)
#   token prometheus@pve!monitoring, privilege-separation off (inherits the
#         user's read-only role)
#
# The token secret is shown only once, at creation. It goes straight from here
# into the container with `pct exec` and never leaves the cluster. If the CT's
# copy is missing (CT rebuilt) or the token is gone, the token is recreated.
# Idempotent.
set -euo pipefail

CT=120
PVE_USER=prometheus@pve
TOKEN=monitoring
CONF=/etc/prometheus/pve.yml
CA=/etc/prometheus/pve-root-ca.pem

pveum user list --output-format json | grep -q "\"userid\":\"${PVE_USER}\"" \
  || pveum user add "$PVE_USER" --comment "prometheus-pve-exporter (CT ${CT} monitoring), read-only"
pveum acl modify / --users "$PVE_USER" --roles PVEAuditor

# The cluster CA, so the exporter verifies the nodes' certificates.
pct exec "$CT" -- sh -c "cat > $CA && chmod 0644 $CA" < /etc/pve/pve-root-ca.pem

token_exists() { pveum user token list "$PVE_USER" --output-format json | grep -q "\"tokenid\":\"${TOKEN}\""; }
if token_exists && pct exec "$CT" -- grep -q "token_name: ${TOKEN}" "$CONF" 2>/dev/null; then
  echo "pve token: present"
  exit 0
fi

token_exists && pveum user token remove "$PVE_USER" "$TOKEN"
secret=$(pveum user token add "$PVE_USER" "$TOKEN" --privsep 0 \
           --comment "prometheus-pve-exporter" --output-format json \
         | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"])')

printf 'default:\n  user: %s\n  token_name: %s\n  token_value: "%s"\n  verify_ssl: %s\n' \
    "$PVE_USER" "$TOKEN" "$secret" "$CA" \
  | pct exec "$CT" -- sh -c "umask 027; cat > $CONF && chown root:prometheus $CONF"
pct exec "$CT" -- systemctl restart prometheus-pve-exporter
echo "pve token: (re)created and installed in CT ${CT}"
