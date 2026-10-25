# 0019 — A temporary LLM serving bench lab: a client on VLAN 20, one pinhole into the LAB

**Status:** accepted (2026-10-25), **temporary**: removed once the operator's
Medium article on the results is published. Asked for by the operator; the
shape below is Claude's recommendation on their spec, accepted.

## Context

The operator benchmarks three inference engines (Ollama, vLLM, SGLang) on
the RTX 3060 in the `ai` VM (ADR 0012) for an article. A benchmark needs a
load generator that is not the server itself (GuideLLM for throughput and
latency, lm-eval for accuracy against the served model), metrics from the
engine and the hardware while it runs, and a way to keep downloads and
updates from competing with a measured run.

Constraints:

- `ai` sits on the LAB VLAN, an untrusted zone (ADR 0013, 0014): it never
  joins the tailnet and never opens anything into another lab VLAN.
- pve1 has one NVMe (thin pool 337 GB; `ai` 250 GB, `hermes` 16 GB): a
  second data disk would be no faster and would overcommit it.
- pve2 has ~3 GB of memory free; pve3 gets nothing new.
- The observability standard adds exporters only for what the Proxmox API
  cannot see.

## Decision

- **`llm-bench`, CT 201 on pve2, VLAN 20** (`services/llm-bench/`): Debian 13
  (the repo's template; Python 3.13 runs both tools), 4 cores, **2 GB**
  (the model runs on `ai`; the client stays light), 32 GB, normal PBS
  backups, which keep the results. A venv at `/opt/bench` with GuideLLM,
  lm-eval, pandas and matplotlib, torch as the CPU build. Static IP from
  `lab.yaml` (VLAN 20 has no DHCP). No chrony: an unprivileged container
  runs on the host's clock.
- **One exact hEX pinhole, VLAN 20 → LAB:** `llm-bench` → `ai:8000`
  (`forward_bench_ai`), the engine's OpenAI-compatible API. Nothing opens
  the other way; replies ride the established-connection rule. The first
  rule from VLAN 20 into the LAB.
- **Monitoring pulls three ports from `ai`**, generated from its
  `lab.yaml` block like every other host: 9835 (GPU, ADR 0014), **9100
  node_exporter** and **8000 the engine's `/metrics`**, all in the
  untrusted-zone job (`service_dmz`, sample and label limits).
  node_exporter is a temporary exception to the standard: per-core CPU in
  the VM shows a tokenizer or scheduler pinned on one core, which the
  Proxmox API averages away. `:8000` is down whenever no engine runs and
  during Ollama runs (Ollama has no `/metrics`); `ai` is best-effort, so
  that `TargetDown` is `info`, a silent record, never a page. Accepted as
  the cheap option for a temporary lab.
- **An internet kill switch for `ai`,** `forward_ai_no_internet`: a drop
  rule on `ai` → WAN, created disabled, flipped by the operator during
  measured runs. Tofu ignores its `disabled` attribute (`ignore_changes`),
  so a flip is not drift.
- **In `ai`** (`services/ai/provision.sh`): chrony replaces timesyncd,
  node_exporter, `/data/{models,results}` as a directory on the root disk
  (no second disk, no Docker data-root move). `converge.sh` takes one
  disk-only snapshot, `bench-baseline`, after provisioning (a VM with a
  passed-through GPU cannot save its RAM).
- **No inference engines or models are installed by code.** Running the
  experiments is the operator's own work.

## Consequences

- Rolling `ai` back to `bench-baseline` stops the VM and wipes everything
  written since, `/data` included; results worth keeping go to `llm-bench`.
- The snapshot holds old blocks as the disk changes; deleting it at
  teardown frees them.
- `hermes` (CT 141) shares the LAB VLAN with `ai` and can reach `:8000`
  without the hEX. Not a path into the lab; accepted for the lab's life.
- **Teardown** (one change, then converge; checklist in
  `services/llm-bench/README.md`): remove `llm-bench` from `lab.yaml` and
  its `.tf`/`logs.tf` lines, the two hEX rules, ports 9100/8000 from `ai`,
  the bench block in `provision.sh` and `converge.sh`; delete the snapshot;
  write a short ADR that supersedes this one ("removed").
