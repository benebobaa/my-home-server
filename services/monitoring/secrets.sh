#!/usr/bin/env bash
# monitoring: install the secrets — Alertmanager receivers (Telegram bot,
# healthchecks.io ping URL), the snmp_exporter SNMPv3 credentials and the
# Grafana admin password.
#
# Reads KEY=value lines on stdin. Run by OpenTofu
# (terraform_data.monitoring_secrets) as:
#   ssh root@pve2 (pinned host key) -> pct exec 120 -> this script
# so the values never cross an SSH hop without host-key verification.
# Empty Telegram / healthchecks values are fine: that receiver is swapped for
# `blackhole` until the operator has created the account.
set -euo pipefail

SRC=/root/monitoring
SECRETS=/etc/prometheus/secrets

declare -A V
while IFS= read -r line; do
  [ -n "$line" ] && V[${line%%=*}]=${line#*=}
done
for k in GRAFANA_ADMIN_PASSWORD SNMP_AUTH_PASSWORD SNMP_PRIV_PASSWORD; do
  [ -n "${V[$k]:-}" ] || { echo "missing $k on stdin" >&2; exit 1; }
done
tg_token=${V[TELEGRAM_BOT_TOKEN]:-}
tg_chat=${V[TELEGRAM_CHAT_ID]:-}
hc_url=${V[HEALTHCHECKS_PING_URL]:-}

umask 077
install -d -m 0750 -o root -g prometheus "$SECRETS"
put() { printf '%s' "$2" > "$SECRETS/$1"; chown root:prometheus "$SECRETS/$1"; chmod 0640 "$SECRETS/$1"; }
put telegram_bot_token "$tg_token"
put healthchecks_ping_url "$hc_url"

# --- Alertmanager ------------------------------------------------------------
am=$(mktemp)
{
  echo "# managed by services/monitoring/secrets.sh — edit the repo copy, not this file."
  # Unconfigured: an inert placeholder (amtool rejects 0); that receiver is
  # unused then (swapped for blackhole below).
  sed "s/__TELEGRAM_CHAT_ID__/${tg_chat:-1}/" "$SRC/alertmanager/alertmanager.yml"
} > "$am"
if [ -z "$tg_token" ] || [ -z "$tg_chat" ]; then
  sed -i 's/^\(\s*receiver:\) telegram\(_silent\)\{0,1\}$/\1 blackhole/' "$am"
  echo "alertmanager: Telegram not configured yet → alerts go to blackhole"
fi
if [ -z "$hc_url" ]; then
  sed -i 's/^\(\s*receiver:\) healthchecks$/\1 blackhole/' "$am"
  echo "alertmanager: healthchecks.io not configured yet → Watchdog goes to blackhole"
fi
amtool check-config "$am" >/dev/null
install -m 0640 -o root -g prometheus "$am" /etc/prometheus/alertmanager.yml
rm -f "$am"
systemctl enable -q prometheus-alertmanager
systemctl restart prometheus-alertmanager

# --- snmp_exporter: SNMPv3 user `monitoring` on the hEX (network/routeros/snmp.tf)
cat > /etc/prometheus/snmp-auth.yml <<EOF
# managed by services/monitoring/secrets.sh
auths:
  hex_v3:
    version: 3
    username: monitoring
    security_level: authPriv
    auth_protocol: SHA
    password: "${V[SNMP_AUTH_PASSWORD]}"
    priv_protocol: AES
    priv_password: "${V[SNMP_PRIV_PASSWORD]}"
EOF
chown root:prometheus /etc/prometheus/snmp-auth.yml
chmod 0640 /etc/prometheus/snmp-auth.yml
systemctl restart prometheus-snmp-exporter

# --- Grafana admin -------------------------------------------------------------
printf '%s\n' "${V[GRAFANA_ADMIN_PASSWORD]}" \
  | grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
      admin reset-admin-password --password-from-stdin >/dev/null
chown -R grafana:grafana /var/lib/grafana

echo "monitoring secrets installed (telegram: $([ -n "$tg_token" ] && echo set || echo unset), healthchecks: $([ -n "$hc_url" ] && echo set || echo unset))"
