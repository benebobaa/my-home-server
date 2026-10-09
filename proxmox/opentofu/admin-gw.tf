# admin-gw — the Tailscale subnet router that makes the lab manageable from
# anywhere (no inbound ports at home; see docs/design/network-design.md).
#
# Service notes: services/admin-gw/README.md
# The hEX already allows 10.10.10.15 (firewall address-list "admin-gw") into
# the lab — no router changes needed for this stack.

resource "proxmox_download_file" "debian_13_template" {
  node_name    = local.host["admin-gw"].node
  datastore_id = "local"
  content_type = "vztmpl"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
}

module "admin_gw" {
  source = "./modules/lxc-guest"

  host             = local.host["admin-gw"]
  description      = "admin-gw — Tailscale subnet router (advertises 10.10.10.0/24, 192.168.99.0/29). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["admin", "tofu"]
  template_file_id = proxmox_download_file.debian_13_template.id
  ssh_public_key   = local.admin_ssh_public_key

  memory_mb = 512
  disk_gb   = 3
}

moved {
  from = proxmox_virtual_environment_container.admin_gw
  to   = module.admin_gw.proxmox_virtual_environment_container.this
}

# In-guest bootstrap (installs Tailscale, IP forwarding), through the node's
# pinned root SSH + `pct exec` like every other guest. The interactive
# `tailscale up` login + route approval are account-level and happen by hand
# once — see services/admin-gw/README.md.
#
# Rebuild caveat: the operator Mac reaches the nodes through admin-gw itself.
# Rebuilding it needs the P7 cable (or the second subnet router, design §9).
resource "terraform_data" "admin_gw_setup" {
  triggers_replace = [
    filesha256("${path.module}/../../services/admin-gw/provision.sh"),
    module.admin_gw.generation,
  ]

  provisioner "local-exec" {
    command = "${local.node_ssh[module.admin_gw.node]} 'pct exec ${module.admin_gw.vmid} -- bash -s' < ${path.module}/../../services/admin-gw/provision.sh"
  }
}

# PVE root-only step: TUN passthrough for the container (API tokens cannot
# write dev* config), then reboot it. Idempotent; script:
# files/admin-gw-root-config.sh.
resource "terraform_data" "admin_gw_tun" {
  triggers_replace = [
    filesha256("${path.module}/files/admin-gw-root-config.sh"),
    module.admin_gw.generation,
  ]

  provisioner "local-exec" {
    command = "${local.node_ssh[module.admin_gw.node]} 'bash -s -- ${module.admin_gw.vmid}' < ${path.module}/files/admin-gw-root-config.sh"
  }

  depends_on = [terraform_data.admin_gw_setup]
}
