#!/usr/bin/env bash
# Print the tailnet policy with the logins filled in, for pasting into the
# Tailscale admin console (Access controls → JSON editor):
#
#   network/tailscale/render-policy.sh | pbcopy
#
# policy.hujson holds the policy; identities.sops.env the logins it names
# (the repo is public):
#   OPERATOR_LOGIN       the operator's Tailscale login
#   LARASROUTER_READERS  handle=login,... (handle as in postgres_readers)
# Edit them with `sops network/tailscale/identities.sops.env`.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${RENDER_POLICY_INNER:-}" ]; then
  RENDER_POLICY_INNER=1 exec sops exec-env identities.sops.env ./render-policy.sh
fi

login_re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
[[ ${OPERATOR_LOGIN:-} =~ $login_re ]] || { echo "render-policy: OPERATOR_LOGIN is not a login" >&2; exit 1; }
[ -n "${LARASROUTER_READERS:-}" ] || { echo "render-policy: LARASROUTER_READERS is empty" >&2; exit 1; }
logins=()
IFS=',' read -ra pairs <<< "$LARASROUTER_READERS"
for pair in "${pairs[@]}"; do
  [[ $pair == *=* && ${pair#*=} =~ $login_re ]] || { echo "render-policy: LARASROUTER_READERS entry '${pair%%=*}' has no login" >&2; exit 1; }
  logins+=("${pair#*=}")
done
list=$(printf '"%s", ' "${logins[@]}")
list=${list%, }

# shellcheck disable=SC2016 # the ${...} below are the template's placeholders, not shell
while IFS= read -r line || [ -n "$line" ]; do
  line=${line//'${OPERATOR_LOGIN}'/$OPERATOR_LOGIN}
  line=${line//'${LARASROUTER_READERS}'/$list}
  if [[ $line == *'${READER}'* ]]; then
    for login in "${logins[@]}"; do printf '%s\n' "${line//'${READER}'/$login}"; done
  else
    printf '%s\n' "$line"
  fi
done < policy.hujson
