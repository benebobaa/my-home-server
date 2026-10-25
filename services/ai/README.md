# ai — the AI workstation VM

VM 140 on **pve1**, Ubuntu 24.04 LTS, the RTX 3060 by VFIO passthrough, on
the LAB VLAN (`10.10.30.10`, internet only). The operator's machine for the
AI/LLM/AI-infra study plan: NVIDIA driver + CUDA toolkit, Docker with the
NVIDIA container toolkit (vLLM, SGLang, TensorRT-LLM images), uv for
Python. Why it looks like this:
[ADR 0012](../../docs/decisions/0012-pve1-on-demand-ai-workstation.md).

| | |
| --- | --- |
| CPU / RAM | 10 cores (`host`), 24 GB pinned (no ballooning: VFIO) |
| Disk | 250 GB on pve1's `local-lvm`, **not backed up** (rebuildable; work lives in Git) |
| GPU | `hostpci0: 0000:0b:00,pcie=1` (VGA + audio); the host binds it to `vfio-pci` (Ansible `vfio`) |
| Login | user `bene`, the admin SSH key, passwordless sudo; no passwords |
| Console | serial (`qm terminal 140` on pve1) — no VGA |
| Starts | with pve1 (`onboot`): wake pve1 and the VM comes up by itself |
| Monitoring | ping + PVE API, and GPU metrics from `nvidia_gpu_exporter` `:9835` (pulled by Prometheus; dashboard **Nvidia GPU Metrics**, alerts `GpuHot`, `GpuHardwareSlowdown`; ADR 0014). No logs leave the VM (ADR 0013) |
| Bench lab (temporary, [ADR 0019](../../docs/decisions/0019-temporary-llm-serving-bench-lab.md)) | node_exporter `:9100`, the engine's `:8000/metrics`, chrony, `/data/{models,results}` on the root disk, snapshot `bench-baseline`; `llm-bench` may reach `:8000`. Use and teardown: [`services/llm-bench/`](../llm-bench/README.md) |

## Files

| File | Runs | Does |
| --- | --- | --- |
| `vm.sh` | on pve1 as root (`terraform_data.ai_vm`) | creates the VM from the pinned cloud image, sets GPU passthrough, CPU, memory, network; never restarts a running VM |
| `user-data.yaml.tftpl` | cloud-init, first boot | hostname, user + key, guest agent |
| `converge.sh` | on pve1 (`terraform_data.ai_converge`) | waits for the agent, runs `provision.sh` in the guest, one reboot for the driver, `nvidia-smi` check |
| `provision.sh` | in the guest as root | full upgrade, driver (branch pinned), CUDA toolkit, Docker + NVIDIA runtime, uv, GPU exporter (pinned, sha256); GPU profiling for every user (`ncu`/`nsys` without root), persistence mode on; purges Tailscale and the journal uploader |

Why scripts and not a bpg VM resource: pve1 is off most days and the PVE
API cannot read an offline node, so a provider resource would break every
`tofu plan`. Consequence: **plan does not detect drift on this VM.** To
re-converge it on purpose (pve1 up):

```bash
cd proxmox/opentofu
sops exec-env secrets.sops.env 'tofu apply -replace=terraform_data.ai_vm -replace=terraform_data.ai_converge'
```

## Access (operator)

`ai` is **not** on the tailnet and ships no logs
([ADR 0013](../../docs/decisions/0013-ai-vm-off-the-tailnet.md)): it runs
untrusted code with passwordless sudo. The admin gateways advertise a route
to it (`10.10.30.10/32`, `services/admin-gw/provision.sh`); approve that
route once in the Tailscale admin console (Machines → `admin-gw` and
`admin-gw2` → Edit route settings). Then from the Mac:

```bash
ssh bene@10.10.30.10
```

Add to `~/.ssh/config` so VS Code (Remote-SSH) and port forwards are short:

```text
Host ai
  HostName 10.10.30.10
  User bene
  LocalForward 8888 localhost:8888   # Jupyter
  LocalForward 8000 localhost:8000   # vLLM / SGLang OpenAI API
```

## Daily use

1. Wake pve1 ([node-ops](../../docs/runbooks/node-ops.md#wake-pve1)); `ai`
   starts with it (~1–2 min).
2. Work: `nvidia-smi`, `uv venv && uv pip install torch`, `docker run --gpus all …`,
   profile with `ncu` / `nsys` (CUDA bin is on `PATH` at login).
3. Shut down pve1 when done (UI or `ssh root@10.10.10.11 poweroff`): it
   stops the VM cleanly first.

## Upgrading the driver or CUDA

Edit `NVIDIA_BRANCH` / `CUDA_TOOLKIT` in `provision.sh` and apply (the
trigger re-runs it). Snapshot first if the VM holds work in progress:
`qm snapshot 140 pre-driver` on pve1 (`qm rollback 140 pre-driver` to undo).
The toolkit's CUDA version must not exceed what the driver supports (the
`CUDA Version` in `nvidia-smi`'s header).

## Baseline (2026-10-13)

What healthy looks like, to compare against when something feels off:

| Check | Value |
| --- | --- |
| fp16 matmul 8192², sustained 60 s (PyTorch 2.14, cu130) | 26.9 TFLOPS (short 20-iteration runs: 22.6–23.2, they include the clock ramp from idle) |
| Same, exporter scraped every second (30× the real rate) | 26.7 TFLOPS: no measurable cost; `ncu` 5/5 runs OK meanwhile |
| gpu-burn `-tc` (~90 s) | ~22.7 TFLOPS, 0 errors, max 64 °C, fan 33 % |
| Power under load | 170 W = limit = max limit (throttle reason `0x4`, power cap: normal) |
| SM clock under load | 1747–1777 MHz |
| PCIe link | Gen4 x16 |
| Idle | ~14 W in P8, ~40 °C, persistence mode Enabled (right after a boot ~45 W until it settles) |
| 20-min soak: gpu-burn `-tc 1200` + `stress-ng --cpu 10 --cpu-method matrixprod` | gpu-burn OK (0 errors), avg 22.2 TFLOPS (22.7 cold → 22.1 hot); GPU max 75 °C, 170 W, SM 1627–1800 MHz, only throttle reason `0x4`, Gen4 x16 throughout; stress-ng passed |
| Host (pve1) during the soak | Tctl/Tccd1 85–87 °C, peak 89 °C (the 5600 throttles at 90; never reached); kernel log empty, no MCE/AER; ≥4.8 GB RAM still available |

The CPU cooler is the tightest margin: all-core load sits 1–3 °C under the
throttle point. Real training rarely loads all 10 vCPUs; if it does, expect
the CPU to clock down before anything fails. To re-run the soak:
`~/gpu-burn/gpu_burn -tc 1200` with
`stress-ng --cpu 10` alongside, and watch `nvidia-smi`, the host's
`journalctl -k` and `/sys/class/hwmon/*` (k10temp `temp1_input` = Tctl).
