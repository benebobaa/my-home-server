#!/usr/bin/env bash
# archive in-guest bootstrap: Tailscale + File Browser (read-only) + users.
#
# Executed once by OpenTofu's remote-exec after the container is created
# (see ../../proxmox/opentofu/archive.tf). Safe to re-run by hand; it then
# needs /root/archive-users.env again (BENE_PASSWORD=..., IRENE_PASSWORD=...,
# from proxmox/opentofu/secrets.sops.env).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

FB_VERSION=v2.63.23
FB_SHA256=b14db2bb8033caa3f80205eb6578b2ed0744ebd9e716b790bc4a9703ce909e88
FB_DB=/var/lib/filebrowser/filebrowser.db
USERS_ENV=/root/archive-users.env

apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates

# --- Tailscale -------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable tailscaled
# /dev/net/tun only arrives with the root-only step after this script
# (files/archive-root-config.sh), so a first start may fail; the CT reboot
# that follows brings tailscaled up.
systemctl restart tailscaled || true
tailscale set --auto-update 2>/dev/null || true

# --- File Browser (pinned, checksum-verified) ------------------------------
if [ "$(filebrowser version 2>/dev/null | grep -o 'v[0-9.]*' || true)" != "$FB_VERSION" ]; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/fb.tar.gz" \
    "https://github.com/filebrowser/filebrowser/releases/download/${FB_VERSION}/linux-amd64-filebrowser.tar.gz"
  echo "${FB_SHA256}  $tmp/fb.tar.gz" | sha256sum -c --quiet
  tar -xzf "$tmp/fb.tar.gz" -C "$tmp" filebrowser
  install -m 0755 "$tmp/filebrowser" /usr/local/bin/filebrowser
  rm -rf "$tmp"
fi

id filebrowser >/dev/null 2>&1 || useradd --system --home /var/lib/filebrowser --shell /usr/sbin/nologin filebrowser
install -d -o filebrowser -g filebrowser -m 0750 /var/lib/filebrowser
mkdir -p /srv/archive

fb() { runuser -u filebrowser -- /usr/local/bin/filebrowser -d "$FB_DB" "$@"; }

# Read-only for everyone: download/preview only. The bind mount is ro=1 too.
PERMS=(--perm.admin=false --perm.create=false --perm.delete=false --perm.download=true
       --perm.execute=false --perm.modify=false --perm.rename=false --perm.share=false)

[ -f "$FB_DB" ] || fb config init >/dev/null
fb config set --address 127.0.0.1 --port 8080 --root /srv/archive \
  --auth.method json --signup=false --branding.name "Family archive" \
  --commands "" "${PERMS[@]}" >/dev/null

if [ -f "$USERS_ENV" ]; then
  # shellcheck disable=SC1090
  . "$USERS_ENV"
  for u in bene irene; do
    var="${u^^}_PASSWORD"
    if fb users ls 2>/dev/null | awk '{print $2}' | grep -qx "$u"; then
      fb users update "$u" --password "${!var}" "${PERMS[@]}" >/dev/null
    else
      fb users add "$u" "${!var}" "${PERMS[@]}" >/dev/null
    fi
  done
  # The default "admin" user from config init must not survive.
  if fb users ls 2>/dev/null | awk '{print $2}' | grep -qx admin; then
    fb users rm admin >/dev/null
  fi
  shred -u "$USERS_ENV"
fi

cat > /etc/systemd/system/filebrowser.service <<'EOF'
[Unit]
Description=File Browser (family archive, read-only)
After=network-online.target
Wants=network-online.target

[Service]
User=filebrowser
Group=filebrowser
ExecStart=/usr/local/bin/filebrowser -d /var/lib/filebrowser/filebrowser.db
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/filebrowser

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable filebrowser
systemctl restart filebrowser

if tailscale status >/dev/null 2>&1; then
  tailscale serve --bg --https=443 http://127.0.0.1:8080 >/dev/null
  echo "tailscale: up; File Browser served on https://$(tailscale status --json | sed -n 's/.*"DNSName": "\([^"]*\)\.".*/\1/p' | head -1)"
else
  cat <<'EOF'

archive bootstrap complete. Account-level steps remain (operator):

  tailscale up --hostname=archive --accept-dns=false
  tailscale serve --bg --https=443 http://127.0.0.1:8080

Then: disable key expiry, enable HTTPS certificates, share the machine with
Irene. Details: services/archive/README.md
EOF
fi
