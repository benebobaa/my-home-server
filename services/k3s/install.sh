#!/usr/bin/env bash
# K3s for Kubeletto's tenant cluster: the server (`k3s`, pve2) or an agent
# (`k3s-worker`, pve3). Idempotent. Run by OpenTofu (proxmox/opentofu/k3s.tf)
# through the pinned root SSH to the node and `qm guest exec ... bash -s`,
# with one line prepended on stdin: K3S_TOKEN=<cluster join token> (from
# random_password.k3s_token, encrypted state; never argv, never echoed).
#
#   install.sh server
#   install.sh agent <server-ip>
#
# Parity with the rented cluster (2026-10-11): same K3s version, bundled
# Traefik disabled (Kubeletto runs its own), ServiceLB on, pod-max-pids 1024,
# the registry mirror (Kubeletto's registries.yaml). Deliberately different:
# secrets encryption at rest on, kubeconfig root-only, no debug logging,
# reservations sized for 5 GB / 3 GB VMs instead of 16 GB.
set -euo pipefail

ROLE=${1:?usage: install.sh server | agent <server-ip>}
SERVER_IP=${2:-}
[ -n "${K3S_TOKEN:-}" ] || { echo "k3s: K3S_TOKEN missing on stdin" >&2; exit 1; }

K3S_VERSION=v1.35.5+k3s1
# install.sh at that release tag, checked by sha256 (it then verifies the
# binary against the release's sha256sum-amd64.txt itself).
INSTALL_SH_URL=https://raw.githubusercontent.com/k3s-io/k3s/v1.35.5%2Bk3s1/install.sh
INSTALL_SH_SHA256=8598e002e61d658fed7b7542fc6d2c66d8da6eae69e088830105d2ee1ffb6d91

case "$ROLE" in
  server) UNIT=k3s ;;
  agent)
    UNIT=k3s-agent
    [[ $SERVER_IP =~ ^[0-9.]+$ ]] || { echo "k3s: agent needs the server IP" >&2; exit 1; } ;;
  *) echo "k3s: unknown role ${ROLE}" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }

install -d -m 0755 /etc/rancher/k3s
before=$({ cat /etc/rancher/k3s/config.yaml /etc/rancher/k3s/registries.yaml /etc/rancher/k3s/token 2>/dev/null || true; } | sha256sum)

umask 077
printf '%s' "$K3S_TOKEN" > /etc/rancher/k3s/token
umask 022

if [ "$ROLE" = server ]; then
  cat > /etc/rancher/k3s/config.yaml <<'EOF'
# managed by services/k3s/install.sh (homeserver repo) — edit there.
token-file: /etc/rancher/k3s/token
write-kubeconfig-mode: "0600"
disable:
  - traefik
secrets-encryption: true
kubelet-arg:
  - system-reserved=cpu=250m,memory=512Mi
  - kube-reserved=cpu=250m,memory=512Mi
  - pod-max-pids=1024
EOF
else
  cat > /etc/rancher/k3s/config.yaml <<EOF
# managed by services/k3s/install.sh (homeserver repo) — edit there.
server: https://${SERVER_IP}:6443
token-file: /etc/rancher/k3s/token
kubelet-arg:
  - system-reserved=cpu=250m,memory=256Mi
  - kube-reserved=cpu=250m,memory=256Mi
  - pod-max-pids=1024
EOF
fi

# Kubeletto's registry mirror (source: kubeletto repo,
# infra/k8s/cluster-bootstrap/registries.yaml): containerd pulls
# registry.kubeletto.com from the in-cluster registry Service, pinned at
# that ClusterIP. Per node: containerd is node-local. Harmless until the
# registry is deployed.
cat > /etc/rancher/k3s/registries.yaml <<'EOF'
# managed by services/k3s/install.sh (homeserver repo) — edit there.
mirrors:
  registry.kubeletto.com:
    endpoint:
      - "http://10.43.229.215:5000"
EOF
after=$(cat /etc/rancher/k3s/config.yaml /etc/rancher/k3s/registries.yaml /etc/rancher/k3s/token | sha256sum)

if [ "$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}')" != "$K3S_VERSION" ]; then
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$INSTALL_SH_URL"
  echo "$INSTALL_SH_SHA256  $tmp" | sha256sum -c --quiet
  INSTALL_K3S_VERSION=$K3S_VERSION INSTALL_K3S_EXEC=$ROLE sh "$tmp" >/dev/null
  rm -f "$tmp"
  echo "k3s: installed ${K3S_VERSION} (${ROLE})"
elif [ "$before" != "$after" ]; then
  systemctl restart "$UNIT"
  echo "k3s: config changed, ${UNIT} restarted"
fi
systemctl enable -q "$UNIT"
systemctl is-active -q "$UNIT" || systemctl start "$UNIT"

if [ "$ROLE" = server ]; then
  for _ in $(seq 1 60); do
    k3s kubectl get node "$(hostname)" >/dev/null 2>&1 && break
    sleep 3
  done
  k3s kubectl wait --for=condition=Ready "node/$(hostname)" --timeout=180s >/dev/null
fi
echo "k3s: ${ROLE} $(hostname) up ($(k3s --version | awk 'NR==1 {print $3}'))"
