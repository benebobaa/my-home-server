# 0024 — The personal agent is retired; CT 141 is removed

**Status:** accepted (2026-10-28). Supersedes [ADR 0018](0018-personal-agent-on-pve1.md). Its container, gateway, secrets and monitoring are removed.

## Context

The operator no longer uses the personal agent (Hermes Agent with its Telegram gateway, CT 141 on pve1). Keeping it costs memory on pve1 (2 GB) and a live Telegram bot token and OpenCode Go key in the encrypted secrets file. pve1 is now always on ([ADR 0023](0023-pve1-always-on-ai-vm-on-demand.md)), so the agent would run around the clock for nobody.

## Decision

- **CT 141 is removed from pve1.** It was stopped before removal and was `onboot 1`. Its last PBS snapshot (2026-10-25) is kept under the normal retention, so it can be restored.
- **Repo:** `services/hermes/`, `proxmox/opentofu/hermes.tf`, the three `TF_VAR_hermes_*` secrets, the three matching variables, and the `hermes` entry in `inventory/lab.yaml` are removed.
- **Credentials:** the Telegram bot and the OpenCode Go key are still valid at their providers. The operator revokes them there, since the removal does not revoke them.

## Consequences

- pve1 has 2 GB more for the `ai` VM or for future guests.
- Nothing else depended on CT 141: no hEX rule, no tenant, no monitoring target except its own ping and PVE probe, which the generated targets drop.
- If the agent is needed again, restore from PBS (`pct restore` from snapshot 2026-10-25) and reconnect the gateway with a new bot token.
- The accepted ADRs 0018, 0019 and 0023 keep their history. The incident record for 2026-10-16 also stays.

## Verification

- Live: `pct destroy 141 --purge` on pve1 after the PBS snapshot was confirmed. `pct list` on pve1 no longer shows 141.
- `tofu plan` for the Proxmox stack after the repo change shows only the removal of Hermes resources, then `No changes` once applied.
- `make check` passes.
