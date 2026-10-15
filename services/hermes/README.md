# hermes — the personal agent

CT 141 on **pve1**: [Hermes Agent](https://hermes-agent.nousresearch.com)
with its Telegram gateway, the operator's personal agent at
**@hermes_benelabs_bot**. Unprivileged Debian 13 container on the LAB VLAN
(`10.10.30.11`, internet only). Online while pve1 is up. Why it looks like
this: [ADR 0018](../../docs/decisions/0018-personal-agent-on-pve1.md).

| | |
| --- | --- |
| Hermes | v0.22.2, pinned by commit (`provision.sh`); installed under `/home/hermes/.hermes` (code, its own Python/Node/uv, config, memory, sessions) |
| Model | OpenCode Go (`opencode-go`), default `glm-5.3-flash` |
| Gateway | `hermes-gateway.service`, a static root-owned unit (`provision.sh`) running as user `hermes`; Telegram long polling: no open port |
| Allowed | the operator's Telegram user id only (`TELEGRAM_ALLOWED_USERS`) |
| Size | 2 cores, 2 GB ceiling (gateway ~240 MB, container ~280 MB idle), 512 MB swap, 10 GB disk (3.5 GB used) |
| Starts | with pve1 (`onboot`); bot connected about 15 s after the container starts |
| Backup | the nightly PBS job, when pve1 is on at 02:30 |
| Monitoring | ping + PVE API, `best-effort`; no logs leave the container (ADR 0013) |

## Files

| File | Runs | Does |
| --- | --- | --- |
| `ct.sh` | on pve1 as root (`terraform_data.hermes_ct`) | creates the container from the pinned Debian template, converges cores, memory, network, `onboot`; never restarts it |
| `provision.sh` | in the container as root (`terraform_data.hermes_provision`) | packages, user `hermes`, Hermes at the pinned commit (run as `hermes`), the repo-owned config keys, the gateway unit |
| `secrets.sh` | in the container as root (`terraform_data.hermes_secrets`) | merges bot token, allowed user and model key into `~hermes/.hermes/.env` (as `hermes`; other lines kept), restarts the gateway on change |

**Root never runs or follows anything in `/home/hermes`**: the agent owns that
tree and could plant code or symlinks there. Everything Hermes is run as
`hermes`; the unit is written from the repo, not by `hermes gateway install`.
`hermes gateway status` calls that unit "outdated" (its text differs from
what Hermes would generate): expected. Don't run `sudo hermes gateway …
--system`, which would rewrite it as root.

Re-run on purpose (pve1 up):

```bash
cd proxmox/opentofu
sops exec-env secrets.sops.env 'tofu apply -replace=terraform_data.hermes_provision'
```

## Using it

Message **@hermes_benelabs_bot** on Telegram. Useful commands in the chat:
`/model` (switch model, e.g. `deepseek-v4.1-flash`; lasts until the next
provision run), `/new` (fresh session), `/usage` (OpenCode Go quota).

Administration, from the Mac:

```bash
ssh root@10.10.10.11            # pve1
pct enter 141                   # the container
runuser -u hermes -- bash -l    # the agent's account
hermes doctor                   # config + provider check
hermes tools list --platform telegram
journalctl -u hermes-gateway -f
```

## Secrets

In `proxmox/opentofu/secrets.sops.env`:

| Key | What |
| --- | --- |
| `TF_VAR_hermes_telegram_bot_token` | @hermes_benelabs_bot's token (its own bot, not the alerts bot) |
| `TF_VAR_hermes_telegram_allowed_users` | the operator's numeric Telegram id (same as the alerts chat id) |
| `TF_VAR_hermes_opencode_go_api_key` | an API key from the OpenCode Console workspace that holds the Go subscription |

Rotate: revoke at the source (BotFather `/revoke`; OpenCode Console → API
keys), `sops edit proxmox/opentofu/secrets.sops.env`, then
`tofu apply` in `proxmox/opentofu` (pve1 up): `secrets.sh` restarts the
gateway.

## Upgrading Hermes

Look up the release's branch head (`release/X.Y.Z`), then bump
`HERMES_VERSION`, `HERMES_BRANCH` and `HERMES_COMMIT` together in
`provision.sh` and apply. Don't run `hermes update` in the container: it
moves the checkout off the pinned commit.

## When it breaks

| Symptom | Look at |
| --- | --- |
| Bot silent | pve1 up? `pct status 141`; `systemctl status hermes-gateway`; the journal shows `Connected to Telegram (polling mode)` on a healthy start |
| `Conflict: terminated by other getUpdates request` | a second process polls the same token: only this gateway may use it |
| Model errors (`subscription required`, `Global regions`) | the OpenCode Console: the key must come from the workspace with the Go subscription; DeepSeek needs Privacy → Global regions |
| Cron jobs not firing | `/run/user/1000/bus` exists? (`dbus-user-session`, linger for `hermes`) |
