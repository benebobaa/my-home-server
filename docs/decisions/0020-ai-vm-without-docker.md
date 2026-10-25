# 0020 — The `ai` VM runs without Docker; engines run natively

**Status:** accepted (2026-10-25). Asked for by the operator: they want
to work close to the machine, and Docker adds a layer of abstraction. Supersedes the Docker line of
[ADR 0012](0012-pve1-on-demand-ai-workstation.md) ("Docker and the
container toolkit").

## Context

ADR 0012 installed Docker CE and the NVIDIA container toolkit in `ai`
because vLLM, SGLang and TensorRT-LLM ship as images. Nothing used them:
the operator works in `uv` venvs, and the bench lab (ADR 0019) installs no
engine by code. Each of the engines it measures installs natively on
Ubuntu 24.04 with CUDA 13: vLLM and SGLang as pip packages in a venv,
Ollama from its own installer (a systemd unit). The operator's study plan
and the bench article are about the hardware path (CUDA, the driver,
the engine's scheduler, profiling with Nsight); a container runtime between
the engine and the machine is one more layer to see through.

## Decision

- **No Docker, no NVIDIA container toolkit in `ai`.** `provision.sh` purges
  them, their apt repos, `/var/lib/docker`, `/var/lib/containerd` and the
  `docker` group if an earlier version installed them.
- Engines run natively: one `uv` venv per engine (and per version under
  test), models under `/data/models` (`HF_HOME`), listening on
  `0.0.0.0:8000` for the bench (Ollama: `OLLAMA_HOST=0.0.0.0:8000`).

## Consequences

- One less daemon and network stack (Docker's bridge and iptables rules) in
  a VM that runs untrusted code; no root-equivalent `docker` group.
- No image-pinned environments: each engine's version and its CUDA wheels
  are pinned in its venv instead (`uv pip freeze` next to the results).
  Engines that pull conflicting torch/CUDA builds live in separate venvs.
- TensorRT-LLM, which is easiest as NVIDIA's image, would need its pip
  wheels or Docker back (a new ADR).
