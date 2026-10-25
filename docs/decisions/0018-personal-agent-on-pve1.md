# 0018 — The personal agent runs on pve1, on demand, in a plain LXC

**Status:** accepted (2026-10-16). Chosen by the operator; Claude's first
recommendation (an always-on container on pve2) was declined.

## Context

The operator wants a personal AI agent reachable from Telegram: Hermes Agent
(Nous Research, MIT), whose gateway polls Telegram and runs a model-driven
agent with a shell. The models come from the operator's OpenCode Go
subscription (open models; GLM-5.3-Flash and DeepSeek V4.1 Flash are the
cheap ones).

Constraints that shaped it:

- pve2 and pve3 are full (pve2 ~3.8 GB available, pve3 ~1.6 GB). pve1 has
  ~6 GB left beside `ai`'s 24 GB.
- ADR 0012: pve1 is off most days and hosts no always-on service. The
  operator accepts a bot that is only online while pve1 is up; Telegram
  keeps messages sent meanwhile for 24 h.
- The `ai` VM is the operator's learning playground and stays untouched.
- The agent runs shell commands chosen by a model, steered by chat messages
  and by whatever it reads: untrusted code in the sense of ADR 0013.
- The operator asked for the simplest, lightest setup: native install, no
  Docker.

## Decision

- **CT 141 `hermes` on pve1, LAB VLAN (`10.10.30.11`, internet only).** An
  unprivileged Debian 13 container, nesting on (as `modules/lxc-guest`),
  `onboot`: waking pve1 brings the bot online in about a minute. Like `ai`
  it is a root script run from `terraform_data` (`services/hermes/ct.sh`),
  not a bpg resource, because the API cannot read pve1 while it is off.
- **Hermes is installed natively** by its own installer, pinned to a release
  commit (installer fetched from the same commit), as an unprivileged user
  `hermes` without sudo; commands run in the container itself (`local`
  terminal backend). Browser and computer-use tools are not installed; image
  generation, TTS and sub-agent delegation are off for Telegram; speech-to-
  text is off (it would fetch a local Whisper model).
- **Hermes' own systemd system unit** runs the gateway (polling, no open
  port), with linger for the agent user so its cron jobs work.
- **Model: OpenCode Go**, built-in Hermes provider `opencode-go`
  (`OPENCODE_GO_API_KEY`), default `glm-5.3-flash`: no workspace setting
  needed and 0-day retention. DeepSeek V4.1 Flash is the alternative once
  the workspace allows Global regions.
- **Secrets** (bot token, allowed Telegram user id, model key) live in
  `proxmox/opentofu/secrets.sops.env` and reach `~hermes/.hermes/.env` over
  the pinned root SSH and `pct exec` stdin. Only the operator's numeric
  Telegram id is allowed; Hermes refuses everyone else by default.
- **Not on the tailnet, no logs shipped, no route from the Mac** (ADR 0013).
  The operator talks to it through Telegram; administration is
  `pct enter 141` on pve1. Monitoring is a ping plus the PVE API,
  `best-effort`, silenced while pve1 is off.

## Consequences

- **The agent can read its own keys.** With the `local` backend its shell
  runs as the user that owns `.env`. A prompt-injected agent could leak the
  bot token or the model key; both are revocable in a minute (BotFather
  `/revoke`, OpenCode Console), and the Go plan caps spend by design. A
  Docker backend with Hermes' egress proxy would close this; declined for
  simplicity.
- **The agent cannot reach the lab.** LAB is internet-only (hEX inter-VLAN
  deny); giving it access to anything internal is a new decision.
- **Its memory is backed up only when pve1 is on at 02:30** (the nightly
  PBS job covers every guest on a running node). Loss is tolerable: it is a
  conversation history, not a record.
- `tofu plan` does not see drift inside the container; re-running the
  scripts converges it (as for `ai`).
- Upgrades are deliberate: bump the release, branch and commit in
  `services/hermes/provision.sh` and apply. Hermes' own `hermes update`
  would move it off the pinned commit.
