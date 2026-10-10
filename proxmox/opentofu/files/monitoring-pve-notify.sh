#!/usr/bin/env bash
# Root-only PVE step (run on pve2 by terraform_data.monitoring_secrets): send
# Proxmox's own notifications (backup jobs, fencing, replication, package
# updates) to the same Telegram chat as Alertmanager — one destination.
#
# Reads TELEGRAM_BOT_TOKEN=… / TELEGRAM_CHAT_ID=… on stdin. The bot token is
# stored as a PVE notification *secret* (/etc/pve/priv/notifications.cfg,
# root-only), referenced from the URL as {{ secrets.token }}. With either value
# empty, the endpoint is removed and the default matcher sends mail only.
# Telegram gets warnings and errors only (matcher telegram-failures): nightly
# "backup OK" messages would be noise (ADR 0009). Everything still goes to
# mail-to-root through the default matcher.
# Cluster-wide config (/etc/pve): running it on one node covers both.
set -euo pipefail

declare -A V
while IFS= read -r line; do
  [ -n "$line" ] && V[${line%%=*}]=${line#*=}
done
token=${V[TELEGRAM_BOT_TOKEN]:-}
chat=${V[TELEGRAM_CHAT_ID]:-}

EP=/cluster/notifications/endpoints/webhook/telegram
b64() { printf '%s' "$1" | base64 -w0; }

MATCHER=/cluster/notifications/matchers/telegram-failures

if [ -z "$token" ] || [ -z "$chat" ]; then
  pvesh set /cluster/notifications/matchers/default-matcher --target mail-to-root
  pvesh delete "$MATCHER" 2>/dev/null || true
  pvesh delete "$EP" 2>/dev/null || true
  echo "pve notifications: Telegram not configured yet (mail-to-root only)"
  exit 0
fi

# Telegram sendMessage, plain text. `escape` makes title/message JSON-safe.
body=$(printf '{"chat_id": "%s", "text": "{{ escape title }}\\n\\n{{ escape message }}"}' "$chat")
args=(--method post
      --url 'https://api.telegram.org/bot{{ secrets.token }}/sendMessage'
      --header "name=Content-Type,value=$(b64 application/json)"
      --body "$(b64 "$body")"
      --secret "name=token,value=$(b64 "$token")"
      --comment "Telegram (managed by OpenTofu: proxmox/opentofu/monitoring.tf)")
if pvesh get "$EP" >/dev/null 2>&1; then
  pvesh set "$EP" "${args[@]}"
else
  pvesh create /cluster/notifications/endpoints/webhook --name telegram "${args[@]}"
fi
pvesh set /cluster/notifications/matchers/default-matcher --target mail-to-root
margs=(--target telegram --match-severity "warning,error,unknown" --mode all
       --comment "warnings and failures → Telegram (managed by OpenTofu: proxmox/opentofu/monitoring.tf)")
if pvesh get "$MATCHER" >/dev/null 2>&1; then
  pvesh set "$MATCHER" "${margs[@]}"
else
  pvesh create /cluster/notifications/matchers --name telegram-failures "${margs[@]}"
fi
echo "pve notifications: Telegram endpoint set; warnings and errors → Telegram, everything → mail-to-root"
