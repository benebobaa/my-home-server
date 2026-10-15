#!/usr/bin/env bash
# hermes secrets: reads KEY=VALUE lines on stdin (OpenTofu,
# terraform_data.hermes_secrets) and sets them in ~hermes/.hermes/.env,
# leaving every other line of that file alone (Hermes writes to it too).
# Restarts the gateway when something changed. Never prints a value.
#
# The merge runs as the agent user, not root: the agent owns that directory
# and could swap the file for a symlink, which root would then follow.
set -euo pipefail

ENV_FILE=/home/hermes/.hermes/.env

# shellcheck disable=SC2016  # Python, not shell
result=$(runuser -u hermes -- python3 -c '
import os, sys, tempfile

path = sys.argv[1]
new = dict(line.split("=", 1) for line in sys.stdin.read().splitlines() if "=" in line)
for key, value in new.items():
    if not value:
        sys.exit(f"secrets.sh: {key} is empty")

os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
try:
    with open(path) as f:
        old = f.read()
except FileNotFoundError:
    old = ""

out, seen = [], set()
for line in old.splitlines():
    key = line.split("=", 1)[0].strip()
    if key in new:
        if key not in seen:
            out.append(f"{key}={new[key]}")
            seen.add(key)
        continue
    out.append(line)
out += [f"{k}={v}" for k, v in new.items() if k not in seen]
text = "\n".join(out) + "\n"

if text == old:
    print("unchanged", len(new))
    sys.exit()
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".env.")
with os.fdopen(fd, "w") as f:
    f.write(text)
os.replace(tmp, path)
print("changed", len(new))
' "$ENV_FILE")

if [ "${result% *}" = changed ] || ! systemctl is-active -q hermes-gateway.service; then
  echo "hermes: (re)starting the gateway"
  systemctl restart hermes-gateway.service
fi
echo "hermes: secrets ${result% *} (${result#* } keys)"
