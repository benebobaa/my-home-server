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
