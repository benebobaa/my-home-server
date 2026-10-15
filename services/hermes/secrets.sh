#!/usr/bin/env bash
# hermes secrets: reads KEY=VALUE lines on stdin (OpenTofu,
# terraform_data.hermes_secrets) and sets them in ~hermes/.hermes/.env,
# leaving every other line of that file alone (Hermes writes to it too).
# Restarts the gateway when something changed. Never prints a value.
set -euo pipefail

ENV_FILE=/home/hermes/.hermes/.env

input=$(cat)
install -d -m 0700 -o hermes -g hermes "$(dirname "$ENV_FILE")"
[ -f "$ENV_FILE" ] || install -m 0600 -o hermes -g hermes /dev/null "$ENV_FILE"

before=$(sha256sum "$ENV_FILE")
INPUT="$input" python3 - "$ENV_FILE" <<'PY'
import os, sys

path = sys.argv[1]
new = dict(line.split("=", 1) for line in os.environ["INPUT"].splitlines() if "=" in line)
for key, value in new.items():
    if not value:
        sys.exit(f"secrets.sh: {key} is empty")

out, seen = [], set()
with open(path) as f:
    for line in f.read().splitlines():
        key = line.split("=", 1)[0].strip()
        if key in new:
            if key not in seen:
                out.append(f"{key}={new[key]}")
                seen.add(key)
            continue
        out.append(line)
out += [f"{k}={v}" for k, v in new.items() if k not in seen]

tmp = path + ".tmp"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    f.write("\n".join(out) + "\n")
os.replace(tmp, path)
PY
chown hermes:hermes "$ENV_FILE"
chmod 0600 "$ENV_FILE"

unit=$(systemctl list-unit-files --no-legend 'hermes-gateway*.service' | awk '{print $1}')
if [ -n "$unit" ] && { [ "$(sha256sum "$ENV_FILE")" != "$before" ] || ! systemctl is-active -q "$unit"; }; then
  echo "hermes: (re)starting the gateway"
  systemctl restart "$unit"
fi
echo "hermes: secrets set ($(printf '%s\n' "$input" | grep -c '=') keys)"
