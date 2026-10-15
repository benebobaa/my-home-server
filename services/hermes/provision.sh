#!/usr/bin/env bash
# hermes in-guest setup: Hermes Agent with its Telegram gateway, the
# operator's personal agent (ADR 0018). Idempotent.
#
# Run by OpenTofu (terraform_data.hermes_provision in
# ../../proxmox/opentofu/hermes.tf) whenever a file in this directory
# changes: the directory is streamed to /root/hermes through the pinned root
# SSH to pve1 + `pct exec`, then this script runs from there. Secrets come
# separately (secrets.sh).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# A release, pinned by its commit (the head of its release branch; the
# installer refuses a commit that is not on the branch it clones). The
# installer comes from the same commit, so code and installer cannot drift
# apart. Bump all three together.
HERMES_VERSION=v0.22.2
HERMES_BRANCH=release/0.22.2
HERMES_COMMIT=d923a5eb487a17c0a68801bba9ef0f56c81040a8

AGENT_USER=hermes
AGENT_HOME=/home/${AGENT_USER}
HERMES_HOME=${AGENT_HOME}/.hermes

# --- base -----------------------------------------------------------------------
apt-get update -qq
apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confold
# git + curl: the installer's prerequisites; libatomic1: its managed Node;
# dbus-user-session: the agent user's bus, which Hermes' cron workers reach
# through `systemd-run --user`.
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git libatomic1 dbus-user-session unattended-upgrades

# The agent's account: no sudo, no password. Its shell commands run as this
# user, inside an unprivileged container on the LAB VLAN (internet only).
id "$AGENT_USER" >/dev/null 2>&1 \
  || useradd --create-home --home-dir "$AGENT_HOME" --shell /bin/bash "$AGENT_USER"

# --- Hermes -----------------------------------------------------------------------
as_agent() { runuser -u "$AGENT_USER" -- env HOME="$AGENT_HOME" HERMES_HOME="$HERMES_HOME" "$@"; }

installed=$(as_agent git -C "${HERMES_HOME}/hermes-agent" rev-parse HEAD 2>/dev/null || true)
if [ "$installed" != "$HERMES_COMMIT" ]; then
  echo "hermes: installing Hermes Agent ${HERMES_VERSION}"
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh"
  chmod 0644 "$tmp"
  # No browser or computer-use tools (no Chromium), no interactive setup:
  # configuration below and in secrets.sh.
  as_agent bash "$tmp" --branch "$HERMES_BRANCH" --commit "$HERMES_COMMIT" --non-interactive \
    --skip-browser --skip-computer-use
  rm -f "$tmp"
fi

HERMES=${AGENT_HOME}/.local/bin/hermes

# --- configuration ------------------------------------------------------------------
# Only the keys the repo owns; Hermes keeps the rest of config.yaml (and
# migrates it on upgrades). Re-set on every run: a model switched from chat
# (/model) lasts until the next provision run.
#   model  OpenCode Go (key in .env, endpoint built in), GLM-5.3-Flash:
#          no workspace setting needed, 0-day retention. DeepSeek V4.1 Flash
#          is the alternative (`/model deepseek-v4.1-flash`) once the
#          workspace allows Global regions.
#   stt    off: the default would fetch a local Whisper model on the first
#          voice note.
as_agent "$HERMES" config set model.provider opencode-go
as_agent "$HERMES" config set model.default glm-5.3-flash
as_agent "$HERMES" config set stt.enabled false
# Toolsets the Telegram agent does without: browser and computer use are not
# installed (--skip-*), image generation and TTS need providers of their
# own, delegation spawns sub-agents on the same quota.
as_agent "$HERMES" tools disable --platform telegram \
  browser computer_use image_gen tts delegation

# --- service ------------------------------------------------------------------------
# Hermes' own system unit (hermes-gateway-<hash>.service, run as the agent
# user, linger enabled). The installer runs as root here, so hand the tree
# back to the agent afterwards.
env HOME=/root HERMES_HOME="$HERMES_HOME" "$HERMES" gateway install \
  --system --run-as-user "$AGENT_USER" --if-missing --no-start-now
chown -R "${AGENT_USER}:${AGENT_USER}" "$AGENT_HOME"

unit=$(systemctl list-unit-files --no-legend 'hermes-gateway*.service' | awk '{print $1}')
[ "$(printf '%s\n' "$unit" | grep -c .)" = 1 ] \
  || { echo "hermes: expected one gateway unit, found: ${unit:-none}" >&2; exit 1; }
systemctl enable "$unit" >/dev/null
# Starts once secrets.sh has written the bot token; restarted on upgrades.
if grep -q '^TELEGRAM_BOT_TOKEN=.' "${HERMES_HOME}/.env" 2>/dev/null; then
  systemctl restart "$unit"
fi

as_agent "$HERMES" --version | head -1
