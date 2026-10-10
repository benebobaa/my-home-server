#!/usr/bin/env bash
# PBS's own notifications (verify, prune and GC job results, sync, updates)
# → the operator's Telegram chat, the same one Alertmanager and Proxmox VE use.
# Warnings and errors only: a success message every night is noise.
#
# Reads TELEGRAM_BOT_TOKEN=… / TELEGRAM_CHAT_ID=… on stdin. Run by OpenTofu
# (terraform_data.pbs_notify) as: ssh root@pve3 (pinned) → pct exec 111 → this.
# The token is stored as a notification *secret* (root-only), referenced from
# the URL as {{ secrets.token }}. With either value empty, the endpoint and its
# matcher are removed (the builtin mail-to-root matcher stays).
# Same webhook shape as proxmox/opentofu/files/monitoring-pve-notify.sh.
set -euo pipefail

declare -A V
while IFS= read -r line; do
  [ -n "$line" ] && V[${line%%=*}]=${line#*=}
done
token=${V[TELEGRAM_BOT_TOKEN]:-}
chat=${V[TELEGRAM_CHAT_ID]:-}

EP=telegram
MATCHER=telegram-failures
pbm() { proxmox-backup-manager "$@"; }
b64() { printf '%s' "$1" | base64 -w0; }

if [ -z "$token" ] || [ -z "$chat" ]; then
  pbm notification matcher delete "$MATCHER" 2>/dev/null || true
  pbm notification endpoint webhook delete "$EP" 2>/dev/null || true
  echo "pbs notifications: Telegram not configured (mail-to-root only)"
  exit 0
fi

body=$(printf '{"chat_id": "%s", "text": "PBS: {{ escape title }}\\n\\n{{ escape message }}"}' "$chat")
args=(--method post
      --url 'https://api.telegram.org/bot{{ secrets.token }}/sendMessage'
      --header "name=Content-Type,value=$(b64 application/json)"
      --body "$(b64 "$body")"
      --secret "name=token,value=$(b64 "$token")"
      --comment "Telegram (managed by services/pbs/notify.sh)")
if pbm notification endpoint webhook list --output-format json | grep -q "\"name\":\"${EP}\""; then
  pbm notification endpoint webhook update "$EP" "${args[@]}"
else
  pbm notification endpoint webhook create "$EP" "${args[@]}"
fi

margs=(--target "$EP" --match-severity "warning,error,unknown" --mode all
       --comment "warnings and failures → Telegram (managed by services/pbs/notify.sh)")
if pbm notification matcher list --output-format json | grep -q "\"name\":\"${MATCHER}\""; then
  pbm notification matcher update "$MATCHER" "${margs[@]}"
else
  pbm notification matcher create "$MATCHER" "${margs[@]}"
fi
echo "pbs notifications: Telegram endpoint set; warnings and errors → Telegram"
