# Experiment: MX130 GPUs (pve2 + pve3)

**Date:** 2026-10-08 · **Nodes:** pve2 (`10.10.10.12`), pve3 (`10.10.10.13`)
**GPU:** NVIDIA GM108M `[GeForce MX130]` — 2048 MiB GDDR5, compute capability 5.0
(Maxwell 1st gen, 2014; rebranded 940MX). One per laptop.

**Goal:** find out what these two always-on laptop GPUs can actually be used for,
and document it. (Design context: the laptops are always-on light-service nodes;
heavy compute belongs to `pve1`'s RTX 3060.)

---

## TL;DR

| Path | Result |
| --- | --- |
| nouveau (open driver) + Mesa RustiCL OpenCL | works — **268.7 MH/s** MD5 |
| NVIDIA 580.178.04 (last Maxwell branch) | works — **2,275.1 MH/s** MD5 (**8.5×**) |
| pve2 (Secure Boot ON) | driver installed + signed; **one-time MOK enrollment pending** |
| pve3 (Secure Boot OFF) | **fully working**: driver loaded, CUDA toolkit 12.8, demo kernel ran |

Both MX130s idle near-zero power (nouveau/nvidia runtime-PM suspend after ~5 s).

## Timeline & findings

1. **Recon** — identical twins (same GM108, same vBIOS `82.08.72.00.93`).
   IOMMU already on; the GPU sits **alone in its own IOMMU group** → ideal for a
   future VFIO passthrough experiment (rehearsal for the RTX 3060 on pve1).
2. **Level 1 — OpenCL via nouveau** (zero proprietary software):
   - Mesa's RustiCL exposes the GPU as `NV118` when enabled:
     `RUSTICL_ENABLE=nouveau clinfo -l` → `Device #0: NV118` (3 SMs, 2047 MB, OpenCL 3.0)
   - hashcat MD5 benchmark: **268.7 MH/s**
     (`RUSTICL_ENABLE=nouveau hashcat -b -m 0 --backend-ignore-cuda`)
3. **Level 2 — NVIDIA driver:**
   - Debian's 550 driver **cannot build** on kernel 7.0.14 (`__vm_flags`, `in_irq()` removed).
   - The last Maxwell-capable branch is **580** — `580.178.04` supports kernels 6.15–7.1.
     Installer: `NVIDIA-Linux-x86_64-580.178.04.run` (kept in `/root/mx130-experiment/`).
   - **pve2:** Secure Boot + lockdown reject unsigned modules → MOK key generated
     (`/var/lib/shim-signed/mok`, CN `homelab Secure Boot MOK`), enrollment queued via
     `mokutil --import` (one-time password recorded on the node, see
     `/root/mx130-experiment/NOTES.txt` — deliberately NOT in this repo).
     Driver installed **signed** + `--skip-module-load` → after the one-time MOK
     enrollment reboot, `nvidia` loads automatically.
   - **pve3:** Secure Boot is off → driver loaded immediately; `nvidia-smi 580.178.04`,
     `compute_cap 5.0`, CUDA 13.0-capable.
4. **CUDA toolkit:** NVIDIA apt repos are signed with legacy SHA-1-certified keys —
   rejected by trixie's `sqv` policy since 2026-02. Workaround: official CUDA
   **12.8.1 runfile** (`--toolkit --silent --override`, no driver, no apt):
   nvcc at `/usr/local/cuda-12.8/bin/nvcc` (12.8 = last toolkit with `sm_50`).
   Gotchas: pve3's `/tmp` is a small tmpfs → pass `--tmpdir=<dir-on-disk>`;
   the runfile wants a TTY → run under `script -qec "..."`; deleted after
   install to save space (re-download from
   `developer.download.nvidia.com/compute/cuda/12.8.1/local_installers/`).
5. **CUDA demo:** `artifacts/vectoradd.cu` compiled with `-arch=sm_50` and ran on pve3:

   ```text
   Device: NVIDIA GeForce MX130 | SM 5.0 | 3 SMs | 1189 MHz | 1995 MiB
   Vector add: 64 Mi elements (256 MiB x 3) | 24.8 ms/rep | 32.5 GB/s | verify OK
   ```

   (glibc-2.41 ↔ CUDA 12.8 header clash: added `noexcept (true)` to six math
   declarations in the toolkit headers; backups `*.pre-mx130` kept on pve3.)

## Numbers

| Benchmark | nouveau + RustiCL | NVIDIA 580 | factor |
| --- | --- | --- | --- |
| hashcat MD5 | 268.7 MH/s | 2,275.1 MH/s | 8.5× |
| vectoradd (pve3) | — | 24.8 ms/rep · 32.5 GB/s · verify OK | |

## Reproduce

```bash
# (on the node, as root)
RUSTICL_ENABLE=nouveau clinfo -l                      # nouveau path
RUSTICL_ENABLE=nouveau hashcat -b -m 0 --backend-ignore-cuda
hashcat -b -m 0                                       # NVIDIA path
/usr/local/cuda-12.8/bin/nvcc -O2 -arch=sm_50 -o vectoradd vectoradd.cu
LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64 ./vectoradd
```

## Node state after the experiment

- **pve2:** nouveau blacklisted + unloaded; NVIDIA 580.178.04 installed via dkms,
  module signed (auto-signing configured in `/etc/dkms/framework.conf`); `nvidia`
  in `/etc/modules-load.d/`; **activation = one-time MOK enrollment**
  (runbook: [`docs/runbooks/secure-boot-mok.md`](../../runbooks/secure-boot-mok.md)).
- **pve3:** fully done (driver loaded; toolkit 12.8; hashcat + nvtop installed).

## Revert (if ever needed)

```bash
sh /root/mx130-experiment/NVIDIA-Linux-x86_64-580.178.04.run --uninstall
rm /etc/modprobe.d/blacklist-nouveau.conf /etc/modules-load.d/nvidia.conf
update-initramfs -u && reboot     # nouveau returns
```
Extra packages on pve2: `clinfo`, `mesa-opencl-icd`, `hashcat`, `dkms`, headers.
On pve3: same + `nvtop` and `/usr/local/cuda-12.8`.

## Next steps

- One-time **MOK enrollment on pve2** (see runbook), then `nvidia-smi` there too.
- AI demo: tiny LLM via llama.cpp (`sm_50` build, ~0.5B model) — "a 2017 GPU runs an LLM".
- Bake-off: same inference on CPU (i3) vs iGPU (OpenVINO) vs MX130 (CUDA).
- Level 3: VFIO passthrough rehearsal (MX130 → throwaway VM) before doing the RTX 3060 on pve1.
