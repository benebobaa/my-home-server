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

## Files

| File | Runs | Does |
| --- | --- | --- |
| `vm.sh` | on pve1 as root (`terraform_data.ai_vm`) | creates the VM from the pinned cloud image, sets GPU passthrough, CPU, memory, network; never restarts a running VM |
| `user-data.yaml.tftpl` | cloud-init, first boot | hostname, user + key, guest agent |
| `converge.sh` | on pve1 (`terraform_data.ai_converge`) | waits for the agent, runs `provision.sh` in the guest, one reboot for the driver, `nvidia-smi` check |
| `provision.sh` | in the guest as root | driver (branch pinned), CUDA toolkit, Docker + NVIDIA runtime, uv; purges Tailscale and the journal uploader |

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
2. Work: `nvidia-smi`, `uv venv && uv pip install torch`, `docker run --gpus all …`.
3. Shut down pve1 when done (UI or `ssh root@10.10.10.11 poweroff`): it
   stops the VM cleanly first.

## Upgrading the driver or CUDA

Edit `NVIDIA_BRANCH` / `CUDA_TOOLKIT` in `provision.sh` and apply (the
trigger re-runs it). Snapshot first if the VM holds work in progress:
`qm snapshot 140 pre-driver` on pve1 (`qm rollback 140 pre-driver` to undo).
The toolkit's CUDA version must not exceed what the driver supports (the
`CUDA Version` in `nvidia-smi`'s header).
