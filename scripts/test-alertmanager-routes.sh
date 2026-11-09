#!/usr/bin/env bash
# Routing regression test for services/monitoring/alertmanager/alertmanager.yml
# (make check, via monitoring-config): which receivers does an alert reach?
# A typo in a matcher would send a critical alert to the wrong place and nothing
# else would notice. Uses `amtool config routes test` on the repo's config with
# only the chat id and the template path substituted (as `make check` does).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cfg=$(mktemp)
trap 'rm -f "$cfg"' EXIT
sed -e 's/__TELEGRAM_CHAT_ID__/1/' \
    -e "s|/etc/prometheus/alertmanager-templates/|$root/services/monitoring/alertmanager/|" \
    "$root/services/monitoring/alertmanager/alertmanager.yml" > "$cfg"

fail=0
expect() { # expect <receivers, comma separated> <label=value>...
  local want=$1
  shift
  if amtool config routes test --config.file="$cfg" --verify.receivers="$want" "$@" >/dev/null 2>&1; then
    echo "  ok   $* -> $want"
  else
    echo "  FAIL $* -> expected $want" >&2
    fail=1
  fi
}

expect healthchecks alertname=Watchdog severity=none
# Telegram failing reports itself on the second path as well as the normal one
expect healthchecks_fail,telegram alertname=AlertmanagerNotificationsFailing severity=warning integration=telegram
expect telegram alertname=PveNodeDown severity=critical instance=pve3
expect telegram alertname=ThinPoolFilling severity=warning instance=pve3
expect telegram_silent alertname=K8sTenantColdStartChurn severity=info
# an alert with no known severity still reaches the default receiver
expect telegram alertname=SomethingNew severity=surprise

if [ "$fail" -ne 0 ]; then
  echo "alertmanager routes: a routing expectation failed" >&2
  exit 1
fi
echo "alertmanager routes: all expectations hold"
