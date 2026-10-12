# 0014 — GPU metrics from nvidia_gpu_exporter; the LAB is an untrusted zone for monitoring

**Status:** accepted (2026-10-13). Asked for by the operator.

## Context

The `ai` VM (ADR 0012) owns pve1's RTX 3060. Its temperature, power, clocks
and VRAM were only visible with `nvidia-smi` / `nvtop` inside the VM: no
history, and no alert while nobody watches a long training run. The
Proxmox API knows nothing about a passed-through GPU. The observability
standard (ADR 0008) says not to add exporters for what the Proxmox API
already gives, with one exception so far: databases (ADR 0010).

The operator asked whether monitoring would slow the GPU down. Collection
that only reads the driver's basic state costs nothing measurable; DCGM's
profiling metrics would use the same counters as Nsight Compute and
conflict with the operator's profiling work (study plan, Phase 4).

ADR 0013 made the LAB VLAN an untrusted zone (code from pip and GitHub runs
there), but the monitoring code still treated only the DMZ that way.

## Decision

- **A guest with a passed-through GPU gets `nvidia_gpu_exporter`**, the
  second exporter exception: pinned release, sha256-checked, installed by
  `services/ai/provision.sh`, `:9835`, default `exec` backend (runs
  `nvidia-smi --query-gpu` per scrape). Basic driver readings only — no
  DCGM, no profiling counters, no per-process metrics.
- **Alerts:** `GpuHot` (≥ 83 °C for 5 min) and `GpuHardwareSlowdown`
  (thermal or power-brake slowdown for 5 min), both `warning` like the
  other temperature alerts. No VRAM alert: inference servers pre-allocate
  most of it by design. Xid error counts need the exporter's experimental
  NVML backend and are not collected.
- **Dashboard:** the exporter author's grafana.com dashboard 14574, pinned
  by revision and sha256 like the other exporter dashboards.
- **The LAB is an untrusted zone for monitoring, like the DMZ:** its
  metrics go to the limited `service_dmz` job, its health URLs use the
  `http_dmz` probe module, and `logs: true` is refused there (inventory
  validation). Monitoring only ever pulls from it.

## Consequences

- `service_dmz`'s `label_limit` goes from 16 to 24: the exporter's
  `nvidia_smi_gpu_info` carries 12 labels, plus 5 target labels.
- The hEX gets one generated rule: monitoring → `ai:9835`.
- While pve1 is off there is no series and nothing fires; the exporter's
  `TargetDown` is suppressed by `PveNodeDown` through the `node` label.
- The laptops' MX130s are not covered (they idle); the same exporter would
  fit their hosts if they ever run real work.
