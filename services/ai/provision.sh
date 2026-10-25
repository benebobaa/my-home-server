#!/usr/bin/env bash
# ai — in-guest setup of the AI workstation VM (ADR 0012). Run as root
# through the guest agent by proxmox/opentofu/ai.tf (`qm guest exec`; the VM
# sits on VLAN 30, which the operator Mac and the nodes cannot route to).
# Idempotent.
#
# Usage: provision.sh <login user>
#
# What it installs, and why this way:
# - NVIDIA driver: Ubuntu's prebuilt, signed modules for the running kernel
#   flavour (`ubuntu-drivers install --gpgpu`: headless, no DKMS), so a
#   kernel update never needs a module build. Pinned to one branch;
#   changing it is a deliberate edit here.
# - CUDA toolkit (nvcc, Nsight) from NVIDIA's repo, toolkit only: the
#   driver stays Ubuntu's. Its version must not exceed what the driver
#   supports (`nvidia-smi` header).
# - uv for Python environments; PyTorch, vLLM and SGLang go into project
#   venvs, not the system. No Docker (operator, 2026-10-25, ADR 0020):
#   engines run natively; purged if an earlier version installed it.
# - nvidia_gpu_exporter for Prometheus (pulled from MGMT; ADR 0014).
#
# Deliberately absent: Tailscale and journal shipping. This VM runs
# untrusted code with passwordless sudo, so it must never sit on the tailnet
# (root could accept the admin gateways' subnet routes into MGMT) or reach
# the log store (VictoriaLogs answers queries on its insert port). The
# operator comes in through the admin gateways' route to it instead
# (services/ai/README.md). Both are purged if an earlier version installed
# them.
set -euo pipefail

USER_NAME=${1:?usage: provision.sh <user>}
NVIDIA_BRANCH=580-server
CUDA_TOOLKIT=cuda-toolkit-13-0

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold)

# cloud-init's own apt run must finish first.
cloud-init status --wait >/dev/null || true

repo() { # repo <name> <keyring url> <list line>
  local key=/etc/apt/keyrings/$1.gpg
  if [ ! -s "$key" ]; then
    curl -fsSL "$2" | gpg --dearmor --yes -o "$key"
    chmod 0644 "$key"
  fi
  printf '%s\n' "$3" > "/etc/apt/sources.list.d/$1.list"
}

install -d -m 0755 /etc/apt/keyrings
# shellcheck source=/dev/null
. /etc/os-release
repo cuda https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub \
  "deb [signed-by=/etc/apt/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /"

# NVIDIA's CUDA repo also carries drivers: never let it supply them.
cat > /etc/apt/preferences.d/cuda-repo-no-drivers <<'EOF'
# managed by services/ai/provision.sh — the driver comes from Ubuntu.
# Driver packages only: a wider glob also blocks the repo's other NVIDIA
# tools.
Package: nvidia-driver-* nvidia-kernel-* nvidia-dkms-* nvidia-headless-* nvidia-utils-* nvidia-compute-utils-* nvidia-firmware-* nvidia-open* nvidia-fabricmanager* libnvidia-compute-* libnvidia-gl-* libnvidia-cfg1-* libnvidia-decode-* libnvidia-encode-* libnvidia-extra-* libnvidia-fbc1-* xserver-xorg-video-nvidia-* cuda-drivers* cuda-compat*
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF

"${APT[@]}" update
"${APT[@]}" install ubuntu-drivers-common
ubuntu-drivers install --gpgpu "nvidia:${NVIDIA_BRANCH}"
"${APT[@]}" install \
  "nvidia-utils-${NVIDIA_BRANCH}" \
  "$CUDA_TOOLKIT" \
  build-essential git curl htop nvtop tmux python3-venv pipx

# No Docker (ADR 0020): purge it, the NVIDIA container toolkit, their repos
# and their data, if an earlier version installed them.
docker_pkgs=$({ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
  'docker-*' containerd.io 'nvidia-container-*' 'libnvidia-container*' 2>/dev/null || true; } | awk '$1 != "un" {print $2}')
if [ -n "$docker_pkgs" ]; then
  systemctl disable --now docker.socket docker.service containerd.service 2>/dev/null || true
  # shellcheck disable=SC2086 # one package per word
  "${APT[@]}" purge $docker_pkgs
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/nvidia-container-runtime
fi
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/nvidia-container-toolkit.list \
  /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/nvidia-container-toolkit.gpg
if getent group docker >/dev/null; then groupdel docker; fi

# Keep the whole system current (unattended-upgrades only takes -security);
# a new kernel brings its NVIDIA modules with it (the -generic module meta).
"${APT[@]}" dist-upgrade
"${APT[@]}" autoremove --purge

# GPU performance counters for every user, not just root: Nsight Compute
# (`ncu`) as the login user fails with ERR_NVGPUCTRPERM otherwise. A
# single-user workstation; the restriction guards shared machines.
want='# managed by services/ai/provision.sh — ncu/nsys without root.
options nvidia NVreg_RestrictProfilingToAdminUsers=0'
if [ "$(cat /etc/modprobe.d/nvidia-profiling.conf 2>/dev/null)" != "$want" ]; then
  printf '%s\n' "$want" > /etc/modprobe.d/nvidia-profiling.conf
  update-initramfs -u
  touch /run/ai-reboot-required
fi

# Persistence mode: keep the driver initialised while no CUDA program runs
# (no 1-2 s CUDA start-up per script, GPU state kept between runs). Ubuntu's
# unit starts the daemon with --no-persistence-mode and only on demand.
install -d /etc/systemd/system/nvidia-persistenced.service.d
want='# managed by services/ai/provision.sh — persistence mode on, always running.
[Unit]
StopWhenUnneeded=false

[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --persistence-mode --verbose

[Install]
WantedBy=multi-user.target'
if [ "$(cat /etc/systemd/system/nvidia-persistenced.service.d/homelab.conf 2>/dev/null)" != "$want" ]; then
  printf '%s\n' "$want" > /etc/systemd/system/nvidia-persistenced.service.d/homelab.conf
  systemctl daemon-reload
  systemctl restart nvidia-persistenced 2>/dev/null || true
fi
systemctl enable -q nvidia-persistenced

# GPU metrics for Prometheus (ADR 0014): nvidia_gpu_exporter on :9835, a
# pinned release checked against the sha256 its release publishes. Default
# `exec` backend: it runs `nvidia-smi --query-gpu` per scrape (the basic
# driver readings: temperature, power, clocks, VRAM, throttle reasons), no
# profiling counters, so `ncu`/`nsys` are unaffected. Its postinst creates
# the service user and enables the unit.
GPU_EXPORTER_VERSION=1.15.1
GPU_EXPORTER_SHA256=0dc8c2756c6853ec7e6a7c404b229d8f764443bef89f33e13b3c4278b309acd4
if [ "$(dpkg-query -W -f='${Version}' nvidia-gpu-exporter 2>/dev/null)" != "$GPU_EXPORTER_VERSION" ]; then
  deb=/tmp/nvidia-gpu-exporter_${GPU_EXPORTER_VERSION}_linux_amd64.deb
  curl -fsSL -o "$deb" "https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v${GPU_EXPORTER_VERSION}/nvidia-gpu-exporter_${GPU_EXPORTER_VERSION}_linux_amd64.deb"
  echo "${GPU_EXPORTER_SHA256}  ${deb}" | sha256sum -c --quiet
  dpkg -i "$deb"
  rm -f "$deb"
fi
systemctl enable -q --now nvidia_gpu_exporter

# nvcc on every login shell's PATH.
cat > /etc/profile.d/cuda.sh <<'EOF'
# managed by services/ai/provision.sh
export PATH=/usr/local/cuda/bin:$PATH
EOF

sudo -u "$USER_NAME" -H pipx install --quiet uv >/dev/null 2>&1 || sudo -u "$USER_NAME" -H pipx upgrade --quiet uv >/dev/null 2>&1 || true
sudo -u "$USER_NAME" -H pipx ensurepath >/dev/null 2>&1 || true

# --- LLM serving bench lab (ADR 0019, temporary: goes with it) ---------------
# chrony instead of timesyncd: the bench client (llm-bench) and this VM time
# the same requests. node_exporter :9100: per-core CPU and memory during a
# run (a tokenizer or scheduler pinned on one core), which the PVE API
# averages away; pulled by monitoring like the GPU exporter (service_dmz).
# No textfile collectors (no recommends). /data is a directory on the root
# disk: pve1 has one NVMe, so a second disk would be no faster and would
# overcommit its thin pool. Models re-download; results worth keeping go to
# llm-bench (backed up), not here.
"${APT[@]}" install --no-install-recommends chrony prometheus-node-exporter
systemctl enable -q --now chrony prometheus-node-exporter
install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 /data /data/models /data/results

# Never on the tailnet, never shipping into MGMT (see the header).
if dpkg -s tailscale >/dev/null 2>&1; then
  tailscale logout 2>/dev/null || true
  "${APT[@]}" purge tailscale
  rm -rf /var/lib/tailscale
fi
rm -f /etc/apt/sources.list.d/tailscale.list /etc/apt/keyrings/tailscale.gpg
systemctl disable --now systemd-journal-upload.service 2>/dev/null || true
if dpkg -s systemd-journal-remote >/dev/null 2>&1; then
  "${APT[@]}" purge systemd-journal-remote
  rm -rf /etc/systemd/journal-upload.conf.d /var/lib/systemd/journal-upload
fi

# A new kernel (dist-upgrade above) or driver needs a reboot to load.
[ -f /var/run/reboot-required ] && touch /run/ai-reboot-required
# The driver loads at the next boot after its first install.
if ! nvidia-smi >/dev/null 2>&1; then
  echo "ai: NVIDIA driver installed; a reboot loads it"
  touch /run/ai-reboot-required
fi
echo "ai: provisioned (driver ${NVIDIA_BRANCH}, ${CUDA_TOOLKIT}, gpu exporter ${GPU_EXPORTER_VERSION}, bench lab; no docker)"
