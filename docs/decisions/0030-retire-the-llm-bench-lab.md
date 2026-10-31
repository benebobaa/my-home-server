# 0030 — The LLM serving bench lab is removed; the lab starts over from zero

**Status:** accepted (2026-10-31). Supersedes [ADR 0019](0019-temporary-llm-serving-bench-lab.md). [ADR 0020](0020-ai-vm-without-docker.md) stays: it is a rule for the `ai` VM, not for the bench.

## Context

The bench lab (ADR 0019, built 2026-10-25) measured Ollama, vLLM and SGLang on the RTX 3060 in the `ai` VM, for an article. On 2026-10-31 the operator asked to remove all of it and start over from zero, rather than keep the lab until the article was out.

## Decision

- **Results kept off the repo.** Before anything was deleted, both result sets were copied to the operator's Mac, outside the repo (`~/Documents/benelabs/llm-bench-results/`): CT 201's `/opt/bench/results` (39 files) and `ai`'s `/data/results` (17 engine logs). Each file was checked against a SHA-256 manifest. The model weights in `/data/models` (11 GB) were not kept; they can be downloaded again.
- **Removed from the repo and the live lab:**
  - CT 201 `llm-bench` on pve2 and its volume (OpenTofu, `module.llm_bench`).
  - The hEX rules `forward_bench_ai` and `forward_ai_no_internet`, and the DNS record `llm-bench.home.arpa`.
  - The bench host in `inventory/lab.yaml`. The `ai` scrape is `[9835]` again: node_exporter `:9100` and the engine's `:8000` are gone.
  - `services/llm-bench/`, and the bench blocks in `services/ai/` (`provision.sh`, `converge.sh`, the README).
- **On `ai`, one-off steps** (not in `provision.sh`, which is idempotent and never removes packages): `chrony` and `prometheus-node-exporter` purged; `systemd-timesyncd` installed and enabled again, Ubuntu's default time sync; `/data` removed; snapshot `bench-baseline` deleted on pve1.
- **Git:** branch tips that held commits not in `main` are kept as local tags, `archive/llm-bench-monitoring` and `archive/backup-pre-strip-2026-10-11`. The branches `llm-bench` and `review/llm-bench-lab` / `review/before-llm-bench` were deleted from origin. `main` is the only branch.

## Consequences

- `ai` is as it was before the bench: the GPU exporter, the NVIDIA driver, CUDA and uv, no Docker, no `/data`, no engines installed. It stays on demand (ADR 0023).
- Nothing scrapes `ai` for engine or CPU metrics any more.
- Starting over is a new decision and will get its own ADR. This one does not choose the next design.
- **Deferred:** `terraform_data.ai_converge` still shows "must be replaced" in the Proxmox plan. Its trigger is the hash of `provision.sh` and `converge.sh`, which changed here. The next converge runs `provision.sh` on `ai` (an apt full upgrade, and a reboot only if the upgrade needs one). It was deferred because `ai` was running and possibly in use. Run `tofu apply -replace=terraform_data.ai_converge` when the operator is ready.
- The Proxmox state had last been written by the `llm-bench-monitoring` branch's `vm.sh`, which turns autostart on. Applying `ai_vm` from `main` brought the state back to `main`'s `vm.sh`. That was a no-op on the live VM (`onboot 0`, no pending changes).

## Verification

- `make check`: all checks passed.
- Proxmox: CT 201 is gone from pve2, and no `vm-201` volume remains. Prometheus has no target at `10.10.30.10` or `10.10.20.40`.
- RouterOS: the plan after the apply shows `No changes`. Router snapshots taken before and after the change: `hex-2026-10-31-212905.rsc` and `hex-2026-10-31-213004.rsc`.
- `ai`: `chrony` and `prometheus-node-exporter` are not installed, `systemd-timesyncd` is active, `NTPSynchronized=yes`, `/data` is absent. `qm listsnapshot 140` shows only `current`.
- Copies: SHA-256 checked for all 56 result files, with zero mismatches.
