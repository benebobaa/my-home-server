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
as_agent() { runuser -u "$AGENT_USER" -- env -C "$AGENT_HOME" HOME="$AGENT_HOME" HERMES_HOME="$HERMES_HOME" "$@"; }

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
# The agent's shell starts in its home, not in the gateway's working
# directory (HERMES_HOME, where its config and memory live).
as_agent "$HERMES" config set terminal.cwd "$AGENT_HOME"
# Toolsets the Telegram agent does without: browser and computer use are not
# installed (--skip-*), image generation and TTS need providers of their
# own, delegation spawns sub-agents on the same quota.
as_agent "$HERMES" tools disable --platform telegram \
  browser computer_use image_gen tts delegation

# --- scraping toolkit -----------------------------------------------------------------
# For the agent's own scripts (its browser tool stays off): Python libraries
# in a venv that is first on its PATH, Playwright's headless Chromium,
# Tesseract OCR with Indonesian. How the agent should use them is the
# skills/scraping-toolkit skill, installed below.
DIR=$(cd "$(dirname "$0")" && pwd)
TOOLKIT=${AGENT_HOME}/.venvs/scrape

# Chromium's libraries: Playwright 1.63's own list for Debian 13 (its
# nativeDeps table; `playwright install-deps --dry-run chromium`), minus
# what a headless scraper of Latin-script sites does without: Xvfb and the
# CJK, Thai and Unifont fonts. Root installs these itself rather than running
# the agent-owned `playwright install-deps`.
apt-get install -y -qq --no-install-recommends \
  python3-venv tesseract-ocr tesseract-ocr-ind jq sqlite3 \
  fonts-liberation fonts-noto-color-emoji fonts-freefont-ttf libfontconfig1 libfreetype6 \
  libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 \
  libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 \
  libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
  libxkbcommon0 libxrandr2

# The venv and the browser belong to the agent (it may add packages); they
# are installed as the agent, from the pinned list.
[ -x "${TOOLKIT}/bin/python" ] || as_agent python3 -m venv "$TOOLKIT"
req=$(mktemp)
install -m 0644 "${DIR}/scraping-requirements.txt" "$req"
as_agent "${TOOLKIT}/bin/pip" install -q --disable-pip-version-check -r "$req"
rm -f "$req"
as_agent "${TOOLKIT}/bin/playwright" install chromium

# The toolkit first on the agent's PATH in login shells (Hermes' terminal
# starts from a login environment); the gateway unit below sets it too.
cat > /etc/profile.d/hermes-toolkit.sh <<EOF
# managed by services/hermes/provision.sh: the agent's scraping toolkit first on PATH
if [ "\$(id -un)" = ${AGENT_USER} ]; then
  case ":\$PATH:" in *":${TOOLKIT}/bin:"*) ;; *) PATH="${TOOLKIT}/bin:\$PATH" ;; esac
fi
EOF

# The skill that tells the agent what is here (written as the agent, into
# its own skills directory; Hermes keeps user skills across updates).
as_agent mkdir -p "${HERMES_HOME}/skills/web/scraping-toolkit"
# shellcheck disable=SC2016  # $1 expands in the agent's shell
as_agent sh -c 'cat > "$1"' sh "${HERMES_HOME}/skills/web/scraping-toolkit/SKILL.md" \
  < "${DIR}/skills/scraping-toolkit/SKILL.md"

# --- service ------------------------------------------------------------------------
# Root never runs or touches anything under the agent's home: the agent owns
# it and could plant code or symlinks there. So no `hermes gateway install`
# as root; this unit is static and root-owned, modelled on the one that
# command generates (v0.22.2), under the bare name Hermes' own CLI expects
# for the agent's default HERMES_HOME. Every Exec* runs as the agent.
# Linger keeps the agent's user manager (and its bus) up for Hermes' cron
# workers.
agent_uid=$(id -u "$AGENT_USER")
agent_bin=${HERMES_HOME}/hermes-agent/.hermes/bin/hermes
cat > /etc/systemd/system/hermes-gateway.service <<EOF
# managed by services/hermes/provision.sh
[Unit]
Description=Hermes Agent Gateway - Messaging Platform Integration
After=network-online.target user@${agent_uid}.service
Wants=network-online.target user@${agent_uid}.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_USER}
WorkingDirectory=${HERMES_HOME}
# One quoted assignment per line: Hermes' CLI reads HERMES_HOME back from
# this file and takes the rest of the line as the value.
Environment="HOME=${AGENT_HOME}"
Environment="USER=${AGENT_USER}"
Environment="LOGNAME=${AGENT_USER}"
Environment="HERMES_HOME=${HERMES_HOME}"
Environment="HERMES_SUPERVISED_CHILD=1"
Environment="PATH=${TOOLKIT}/bin:${AGENT_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${agent_bin} gateway run
ExecReload=/bin/kill -USR1 \$MAINPID
ExecStop=-${agent_bin} --run-module gateway.systemd_stop_mark
ExecStopPost=-${agent_bin} --run-module gateway.cgroup_cleanup
# Hermes' exit codes: 75 = restart me, 78 = fatal config (don't loop).
Restart=always
RestartSec=5
RestartForceExitStatus=75
SuccessExitStatus=75
RestartPreventExitStatus=78
KillMode=mixed
TimeoutStopSec=70

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
loginctl enable-linger "$AGENT_USER"
systemctl enable hermes-gateway.service >/dev/null 2>&1
# Starts once secrets.sh has written the bot token; restarted on upgrades.
if as_agent grep -q '^TELEGRAM_BOT_TOKEN=.' "${HERMES_HOME}/.env" 2>/dev/null; then
  systemctl restart hermes-gateway.service
fi

as_agent "$HERMES" --version | head -1
