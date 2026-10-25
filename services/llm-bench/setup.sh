#!/usr/bin/env bash
# llm-bench in-guest setup (ADR 0019, temporary). Idempotent: run by OpenTofu
# (terraform_data.llm_bench_setup) every time a file in this directory
# changes, from /root/llm-bench in the guest. Holds no secrets.
#
# A load-generator client for the engines under test on `ai` (:8000): a
# Python venv at /opt/bench with GuideLLM, lm-eval, pandas and matplotlib.
# No daemon, no port: the operator runs the benchmarks by hand. Results go
# to /opt/bench/results (on this container's root disk, so PBS backs them
# up nightly; `ai` is not backed up).
#
# No chrony: an unprivileged container cannot set the clock; it runs on
# pve2's (chrony on the host).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

DIR=$(cd "$(dirname "$0")" && pwd)
VENV=/opt/bench/venv
TORCH=2.14.1 # CPU build, see requirements.txt

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git jq python3-venv python3-dev tmux

install -d -m 0755 /opt/bench /opt/bench/results

# Rebuilt only when the pins change (a full install pulls ~1.5 GB).
want=$(cat "$DIR/requirements.txt" <(echo "torch==${TORCH}+cpu") | sha256sum | cut -d' ' -f1)
if [ "$(cat /opt/bench/.requirements.sha256 2>/dev/null)" != "$want" ]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q --index-url https://download.pytorch.org/whl/cpu "torch==${TORCH}+cpu"
  "$VENV/bin/pip" install -q -r "$DIR/requirements.txt"
  echo "$want" > /opt/bench/.requirements.sha256
fi

# The venv on root's PATH at login.
cat > /etc/profile.d/bench.sh <<EOF
# managed by services/llm-bench/setup.sh
. ${VENV}/bin/activate
EOF

# Fail the apply if the tools do not start.
"$VENV/bin/guidellm" --version
"$VENV/bin/lm_eval" --help >/dev/null
"$VENV/bin/python" -c 'import pandas, matplotlib, torch; print("pandas", pandas.__version__, "matplotlib", matplotlib.__version__, "torch", torch.__version__)'
echo "llm-bench setup complete"
