# Proxmox VE provider (bpg/proxmox).
#
# Credentials: the API token is read from the PROXMOX_VE_API_TOKEN environment
# variable and is never stored in the repo. See .env.example and README.md.
#
#   set -a; source .env; set +a
#   tofu plan
#
provider "proxmox" {
  endpoint = var.proxmox_endpoint

  # Self-signed certificate on the lab nodes (management VLAN only).
  insecure = true
}
