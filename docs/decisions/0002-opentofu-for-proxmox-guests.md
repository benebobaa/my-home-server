# 0002 — OpenTofu for Proxmox guests

**Status:** accepted (2026-10-07)

## Context

The guest lifecycle (containers/VMs) was hand-rolled through the Proxmox
UI/CLI — fast to start, but invisible to review and not reproducible. The
router is already OpenTofu (ADR 0001); the Proxmox side should follow, at
least for guests.

Options considered:

- **bpg/proxmox** (community): actively maintained; full LXC + VM coverage
  (device passthrough, initialization, template download); distributed via
  the Terraform Registry.
- **Telmate/proxmox**: older, slower cadence, weaker LXC story.
- **Ansible** (`community.proxmox`): procedural; no state/plan/diff for
  creation — better suited to *host* configuration.
- **Proxmox API scripts (`pvesh`)**: no plan/diff, no state.

## Decision

Provision guests with **OpenTofu + `bpg/proxmox`** (`~> 0.116`), talking to
the Proxmox API over a **scoped API token** (`terraform@pve`: `PVEAdmin` on
`/`, `PVEDatastoreAdmin` on `/storage`, `TofuNetworkAccess` on `/nodes`;
token privilege separation off for a single-operator lab).

## Consequences

- Guests go `tofu plan → review → apply`; state stays local and git-ignored.
- One hand-applied bootstrap remains: the API user/token — documented in
  `proxmox/opentofu/README.md`.
- `/dev/net/tun` (device passthrough) is root-restricted in PVE (API tokens
  cannot set `dev0`); the stack applies it with an idempotent SSH step after
  creation — the provider uses the same approach for `lxc.idmap`.
- Node-level config (repos, logind, interfaces) is still applied by hand;
  moving that to Ansible is the next IaC step (`ansible/`).
- The switch has no usable provider — it stays "config backup + runbook".
- Interactive, account-level Tailscale flows stay manual by design.
