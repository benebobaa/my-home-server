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
| pve2 (Secure Boot now OFF) | **fully working**: driver loaded, **2,309.5 MH/s** MD5, demo kernel ran |
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
| hashcat MD5 (pve3) | 268.7 MH/s | 2,275.1 MH/s | 8.5× |
| hashcat MD5 (pve2) | — | 2,309.5 MH/s | |
| vectoradd (pve2 and pve3) | — | 24.80 ms/rep · 32.5 GB/s · verify OK (identical) | |

The two laptops behave as identical twins; pve2 was benchmarked after Secure Boot was
disabled (2026-10-08) and after a reboot of all nodes — driver persisted. vectoradd on
pve2 uses a binary built on pve3 with `--cudart static` (no CUDA toolkit installed on pve2).

## Pooling both GPUs: llama.cpp over RPC (2026-10-08)

**Question:** can the two MX130s work together? **Answer:** not as one bigger GPU, but
llama.cpp's RPC backend splits a model's layers across both cards over the network, so
their VRAM adds up (2 GB + 2 GB). Setup: `ggml-rpc-server` on pve2 (bound to the
management VLAN, started only for the test; it has **no authentication** — never leave
it running), client `llama-bench` on pve3 with `--rpc 10.10.10.12:50052`.
llama.cpp built once on pve3 (`-DGGML_CUDA=ON -DGGML_RPC=ON -DCMAKE_CUDA_ARCHITECTURES=50`,
CUDA 12.8, about 20 min niced on 4 cores); binaries + the 3 CUDA runtime libs were copied
to pve2. Models: Qwen2.5 Instruct Q4_K_M (1.5B = 1.04 GiB, 3B = 1.95 GiB).
Link between the nodes: 1 GbE, **~4.9 ms RTT**.

| Model | Setup | prompt (tok/s) | generation (tok/s) |
| --- | --- | ---: | ---: |
| 1.5B | CPU only (i3, 4 threads) | 39.7 | 17.3 |
| 1.5B | 1 GPU | 142.6 | 17.8 |
| 1.5B | 2 GPUs (RPC) | 135.8 | 17.1 |
| 3B | CPU only | 19.7 | 8.8 |
| 3B | 1 GPU | out of memory (1.95 GiB model on a ~1.9 GiB card) | |
| 3B | 1 GPU, partial offload (30 layers) | 64.3 | 7.5 |
| 3B | 2 GPUs (RPC) | 65.8 | 7.8 |

During the 3B run both cards held ~1 GB of weights and were busy (pve2 986 MiB, pve3 1073 MiB).

**Takeaways**
- Pooling **works** and is what makes a model too big for one card run fully on GPU, but
  it brings **no speed-up**: layers run one after another, so the cards take turns, and
  the ~5 ms link adds a little (1.5B: 17.8 → 17.1 tok/s).
- Prompt processing is where the GPUs help: 3.6× faster than the CPU on 1.5B, 3.3× on 3B.
- Token generation is memory-bandwidth-bound (~32 GB/s on the GPU, similar to the i3's
  DDR4), so **the CPU matches the GPU** here (17.3 vs 17.8 tok/s on 1.5B).
- The first CPU run (prompt 66 tok/s) was inflated: with the CUDA backend present,
  llama.cpp offloads big batches to the GPU even at `-ngl 0`. Hide the GPU
  (`CUDA_VISIBLE_DEVICES=""`) for a true CPU baseline.
- Embarrassingly parallel work (e.g. hashcat, split keyspace) is the case where two nodes
  scale roughly linearly: 2,309.5 + 2,275.1 ≈ 4.6 GH/s MD5 (not measured together).

**Reproduce**
```bash
# pve2 (never leave running; unauthenticated)
LD_LIBRARY_PATH=. ./ggml-rpc-server -H 10.10.10.12 -p 50052
# pve3
llama-bench -m qwen2.5-3b-instruct-q4_k_m.gguf -ngl 99 --rpc 10.10.10.12:50052 -p 128 -n 32 -r 2
CUDA_VISIBLE_DEVICES="" llama-bench -m <model> -ngl 0 -t 4     # true CPU baseline
```
Files on the nodes: `/root/mx130-experiment/{llama.cpp,models}` (pve3), `/root/mx130-experiment/llama` (pve2).

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

- **pve2:** nouveau blacklisted + unloaded; NVIDIA 580.178.04 installed via dkms
  (module signed; MOK signing is configured in `/etc/dkms/framework.conf` but unused now);
  `nvidia` in `/etc/modules-load.d/`. **Secure Boot was disabled in the BIOS** (same as
  pve3) instead of enrolling the MOK — the queued enrollment was cleared by the reboot.
  Driver loads at boot. (Runbook: [`docs/runbooks/secure-boot-mok.md`](../../runbooks/secure-boot-mok.md).)
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

- Bake-off, remaining part: iGPU (OpenVINO / Vulkan on the HD 620) vs the MX130 and the CPU
  (CPU and MX130 done above).
- Measure hashcat on both nodes at once (keyspace split) to confirm the ~linear scaling.
- Level 3: VFIO passthrough rehearsal (MX130 → throwaway VM) before doing the RTX 3060 on pve1.
