# Proxmox VE provider (bpg/proxmox).
#
# Credentials: the API token is read from the PROXMOX_VE_API_TOKEN environment
# variable, which comes from secrets.sops.env (encrypted). See README.md.
#
#   sops exec-env secrets.sops.env 'tofu plan'
#
provider "proxmox" {
  endpoint = var.proxmox_endpoint

  # Self-signed certificate on the lab nodes (management VLAN only).
  insecure = true
}

# The same API, straight to pve2. URL downloads to a node (`query-url-metadata`)
# time out with HTTP 596 when pve3 proxies them to pve2 (30 s; 2 s direct —
# found 2026-10-11, other proxied calls are fine), so resources that download
# onto pve2 use this. Address from inventory/lab.yaml.
provider "proxmox" {
  alias    = "pve2"
  endpoint = "https://${local.host.pve2.ip}:8006"
  insecure = true
}
