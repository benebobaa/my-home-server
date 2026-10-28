# 0023 — pve1 is always on; the `ai` VM stays on demand

**Status:** accepted (2026-10-28). Supersedes [ADR 0012](0012-pve1-on-demand-ai-workstation.md)'s decision that pve1 runs on demand, and its rule that pve1 hosts no always-on services. ADR 0012's GPU decision stands: the RTX 3060 goes whole to the `ai` VM by VFIO. [ADR 0015](0015-tenant-capacity-by-measured-reservations.md) stands too: pve1 is not a tenant worker.

## Context

pve1 (Ryzen 5 5600, 6 cores, 32 GB, NVMe, RTX 3060) was built to be off most days. Off, it cost the cluster a vote: with pve1 down, two of three votes remain, so losing either laptop as well makes the cluster non-quorate and locks management (AGENTS.md, "Two-node quorum"). The operator wants pve1 running like the other nodes, and the AI VM only while learning AI.

## Decision

- **pve1 is always on**, like pve2 and pve3. Its monitoring tier is now `standard` (it was `best-effort`), so `PveNodeDown` for pve1 is critical when it is down, not a silent note.
- **`ai` (VM 140) is on demand.** It has `onboot 0`, on the host and in `services/ai/vm.sh`. The operator starts it with `qm start 140` on pve1 or from the UI when learning AI, and shuts it down afterwards. While it runs, it holds the GPU and 24 GB of pve1's memory.
- **Wake-on-LAN stays armed** on pve1, as the recovery path after a power cut, not as a routine.
- **The cluster has three votes.** One node down keeps quorum. Two down locks management, as before.
- **Placement:** pve1 may host always-on guests that fit in the memory `ai` leaves free (about 8 GB while `ai` runs). Stateful guests stay on pve2 until a separate decision moves them.

## Consequences

- **Power and noise:** the desktop now runs around the clock. The operator accepts this.
- **Power cuts:** until a UPS is bought (planned, not yet bought), a cut takes pve1 down. It comes back by itself only if the BIOS restores power on AC loss (Restore AC Power Loss = Last State, ErP off, Power On by PCI-E). The steps are in [node-ops](../runbooks/node-ops.md).
- **Hermes:** the personal agent (CT 141, [ADR 0018](0018-personal-agent-on-pve1.md)) is now online around the clock, not only while pve1 is up. Its Telegram bot answers at all times.
- **Kubeletto:** unaffected. pve1 is still not a tenant worker.
- **Documents still describing pve1 as on demand** are not edited here, because the procedures they hold are being rewritten. The follow-up sweep covers `docs/hardware.md`, `docs/design/network-design.md`, `docs/design/kubeletto-home.md`, `docs/runbooks/gpu-lxc-passthrough.md`, `docs/runbooks/proxmox-cluster.md`, `docs/runbooks/proxmox-install.md`, `docs/runbooks/alerts.md`, `docs/runbooks/kubeletto-migration.md`, `services/k3s/README.md`, `services/ai/README.md`, `services/hermes/ct.sh` and `ansible/README.md`. Accepted ADRs (0011, 0013, 0018, 0020) are history and are not edited.

## Verification

- **Cluster (2026-10-28):** `pvecm status` on pve2 shows 3 nodes, `Quorate: Yes`, 3 of 3 votes.
- **`ai`:** `onboot: 0` on pve1. The VM was stopped by an operator task at 20:17, about 40 seconds after pve1 booted, and was not autostarted by the host.
- **Monitoring (2026-10-28):** the targeted OpenTofu apply of `monitoring_setup`, `monitoring_secrets` and `monitoring_targets` succeeded. pve1's scrape target carries `tier: standard`, and `promtool` accepts all 11 rules.
- **Pending on purpose:** `tofu plan` still marks `ai_vm` and `ai_converge` for replacement, because `services/ai/vm.sh` changed (its hash is their trigger). They are not applied while the VM is stopped, because `ai_converge` expects a running guest. The script no longer starts the VM. Apply them the next time the VM is started by hand: `tofu apply -target=terraform_data.ai_vm -target=terraform_data.ai_converge`.
- **Not yet verified:**
  - A cold reboot of pve1 that proves pve1 returns by itself, and that `ai` does not start on its own. The repo's rule is that anything that must survive a boot is proven by a cold reboot. Do it in a planned window, with `ai` off.
  - The BIOS settings. The OS can't read them, so the operator checks them against [node-ops](../runbooks/node-ops.md).
