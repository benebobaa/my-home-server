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
# - Docker CE + NVIDIA container toolkit: vLLM, SGLang and TensorRT-LLM ship
#   as images that expect `--gpus all`.
# - Tailscale: the operator's path in (VLAN 30 is internet-only). Login is
#   the operator's step: `sudo tailscale up --ssh` prints a URL.
# - uv for Python environments; PyTorch goes into projects, not the system.
# - Journal shipping to the lab log store (services/logs/ship.sh is piped
#   in after this script by ai.tf).
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
repo docker https://download.docker.com/linux/ubuntu/gpg \
  "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable"
repo nvidia-container-toolkit https://nvidia.github.io/libnvidia-container/gpgkey \
  "deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /"
repo cuda https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub \
  "deb [signed-by=/etc/apt/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /"
repo tailscale "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
  "deb [signed-by=/etc/apt/keyrings/tailscale.gpg] https://pkgs.tailscale.com/stable/ubuntu ${VERSION_CODENAME} main"

# NVIDIA's CUDA repo also carries drivers: never let it supply them.
cat > /etc/apt/preferences.d/cuda-repo-no-drivers <<'EOF'
# managed by services/ai/provision.sh — the driver comes from Ubuntu.
Package: *nvidia* *cuda-drivers* *cuda-compat*
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF

"${APT[@]}" update
"${APT[@]}" install ubuntu-drivers-common
ubuntu-drivers install --gpgpu "nvidia:${NVIDIA_BRANCH}"
"${APT[@]}" install \
  "nvidia-utils-${NVIDIA_BRANCH}" \
  "$CUDA_TOOLKIT" \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  nvidia-container-toolkit \
  tailscale \
  build-essential git curl htop nvtop tmux python3-venv pipx

# Docker uses the NVIDIA runtime for --gpus.
if ! grep -q nvidia /etc/docker/daemon.json 2>/dev/null; then
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi
usermod -aG docker "$USER_NAME"

# nvcc on every login shell's PATH.
cat > /etc/profile.d/cuda.sh <<'EOF'
# managed by services/ai/provision.sh
export PATH=/usr/local/cuda/bin:$PATH
EOF

sudo -u "$USER_NAME" -H pipx install --quiet uv >/dev/null 2>&1 || sudo -u "$USER_NAME" -H pipx upgrade --quiet uv >/dev/null 2>&1 || true
sudo -u "$USER_NAME" -H pipx ensurepath >/dev/null 2>&1 || true

systemctl enable --now tailscaled

# The driver loads at the next boot after its first install.
if ! nvidia-smi >/dev/null 2>&1; then
  echo "ai: NVIDIA driver installed; a reboot loads it"
  touch /run/ai-reboot-required
fi
echo "ai: provisioned (driver ${NVIDIA_BRANCH}, ${CUDA_TOOLKIT}, docker, tailscale)"
