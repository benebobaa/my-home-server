# 0012 — pve1 is an on-demand AI workstation: the RTX 3060 goes to one VM

**Status:** accepted (2026-10-13). Chosen by the operator from Claude's
recommendation.

## Context

pve1 arrived on 2026-10-12: ASUS PRIME B550M-A, Ryzen 5 5600, 32 GB,
RTX 3060 12 GB, one 500 GB NVMe ([hardware](../hardware.md)). The operator
bought it to study AI, LLMs and AI infrastructure (PyTorch, CUDA and Triton
kernels, vLLM, SGLang, llama.cpp, Nsight profiling), about 10–15 GPU hours
a week. Earlier notes had pencilled it in as the K3s host or a second
Kubeletto worker (k3s.tf, ADR 0011), and the repo's plan was always "on
demand, never always-on services".

ADR 0003 shares the laptops' MX130s into LXCs with the host's NVIDIA driver.
That fits a fixed workload, not this one: each tool in the study plan pins
its own driver/CUDA range, Docker images (vLLM, SGLang, TensorRT-LLM) expect
the NVIDIA container toolkit, and Nsight needs profiling counters a
container doesn't get by default.

## Decision

- **pve1 joins the cluster `homelab` as the third node and runs on demand.**
  It is shut down when not in use and woken by Wake-on-LAN (BIOS: ErP off,
  power on by PCI-E; NIC armed by Ansible, `wake_on_lan`). Quorum is
  unchanged in practice: 2 of 3 votes while it is off, so the laptops must
  both be up, as before.
- **The RTX 3060 goes whole to one VM, `ai`, by VFIO passthrough.** The host
  binds the card (VGA + HDMI audio, its own IOMMU group) to `vfio-pci` at
  boot and never loads an NVIDIA driver (Ansible `vfio` tag,
  `vfio_pci_ids`). The VM runs Ubuntu 24.04 LTS, the platform NVIDIA's
  stack and the study material target first, with its own driver, CUDA,
  Docker and the container toolkit. ADR 0003 stays as is for the laptops.
- **No always-on service on pve1.** The Kubeletto VMs stay on pve2/pve3;
  "moves to pve1" in k3s.tf and the worker plan in ADR 0011 are withdrawn.
  Kubeletto's capacity (its D9) is met on the laptops: the cheapest step is
  a 16 GB SODIMM for pve3.
- **`ai` lives on the LAB VLAN (30)**, internet only: it runs code from pip,
  model hubs and GitHub. The operator reaches it over Tailscale running in
  the VM, not through the admin gateways (which route MGMT only), so no
  router pinhole is added.
- **pve1's guests are scripts, not provider resources.** The PVE API cannot
  read an offline node ("proxy handler failed"), so a bpg resource on pve1
  would break `tofu plan` and `make drift` most days. `ai` is created and
  converged by root scripts run from `terraform_data` (`services/ai/`),
  the repo's pattern for root-only config; GPU passthrough is root-only
  anyway. Trade-off: plan does not detect drift on `ai`; re-running the
  scripts converges it.
- **`ai` is rebuildable, not backed up.** Its disk is left out of PBS (the
  datastore is 30 GB; models and datasets re-download); the operator's work
  lives in Git.

## Consequences

- The host has no screen once `vfio-pci` binds (the 5600 has no iGPU).
  Console rescue is a GRUB edit (`module_blacklist=vfio_pci`), recorded in
  the playbook and the install runbook.
- `ai` holds its memory while running (VFIO pins guest RAM): 24 GB of 32,
  so pve1 has little room for other guests while it runs, and that is fine.
- A node that is off by design must not page. pve1 and `ai` are
  `best-effort`; `PveNodeDown` takes its severity from the node's tier;
  every scrape target carries a `node` label, so a node that is down
  suppresses its own and its guests' unreachable/scrape/UI alerts
  (Alertmanager inhibition); `HostRebooted` skips best-effort nodes.
  Shutting pve1 down sends one silent message.
- The 500 GB NVMe is the limit for models and datasets; a second NVMe
  (the board has a free M.2 slot) becomes the data disk when it fills.
