# admin-gw — the Tailscale subnet routers that make the lab manageable from
# anywhere (no inbound ports at home; see docs/design/network-design.md).
#
# Two gateways, one per node, advertising the same routes: Tailscale fails
# clients over to the other when one goes offline, so a sick gateway or a
# node reboot no longer cuts off remote admin (RCA
# docs/incidents/2026-10-09-remote-access-degraded.md).
#
# Service notes: services/admin-gw/README.md
# The hEX trusts both IPs (firewall address-list "admin-gw").

locals {
  admin_gateways = toset(["admin-gw", "admin-gw2"])

  # Container templates are per node (one download resource per node).
  debian_13_template = {
    for t in [proxmox_download_file.debian_13_template, proxmox_download_file.debian_13_template_pve2] : t.node_name => t.id
  }
}

resource "proxmox_download_file" "debian_13_template" {
  node_name    = local.host["admin-gw"].node
  datastore_id = "local"
  content_type = "vztmpl"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
}

module "admin_gw" {
  source   = "./modules/lxc-guest"
  for_each = local.admin_gateways

  host             = local.host[each.key]
  description      = "${each.key} — Tailscale subnet router (advertises 10.10.10.0/24, 192.168.99.0/29). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["admin", "tofu"]
  template_file_id = local.debian_13_template[local.host[each.key].node]
  ssh_public_key   = local.admin_ssh_public_key

  memory_mb = 512
  disk_gb   = 3
}

moved {
  from = proxmox_virtual_environment_container.admin_gw
  to   = module.admin_gw["admin-gw"].proxmox_virtual_environment_container.this
}

moved {
  from = module.admin_gw
  to   = module.admin_gw["admin-gw"]
}

# In-guest bootstrap (installs Tailscale, IP forwarding), through the node's
# pinned root SSH + `pct exec` like every other guest. The interactive
# `tailscale up` login + route approval are account-level and happen by hand
# once per gateway — see services/admin-gw/README.md.
#
# Rebuild one gateway at a time: the operator Mac reaches the nodes through
# the other one while it is down.
resource "terraform_data" "admin_gw_setup" {
  for_each = module.admin_gw

  triggers_replace = [
    filesha256("${path.module}/../../services/admin-gw/provision.sh"),
    each.value.generation,
  ]

  provisioner "local-exec" {
    command = "${local.node_ssh[each.value.node]} 'pct exec ${each.value.vmid} -- bash -s' < ${path.module}/../../services/admin-gw/provision.sh"
  }

  # tailscaled needs /dev/net/tun, so the passthrough (and its CT reboot) must
  # come first; otherwise `tailscale set` fails with "503 no backend".
  depends_on = [terraform_data.admin_gw_tun]
}

moved {
  from = terraform_data.admin_gw_setup
  to   = terraform_data.admin_gw_setup["admin-gw"]
}

# PVE root-only step: TUN passthrough for the container (API tokens cannot
# write dev* config), then reboot it. Runs before admin_gw_setup. Idempotent;
# script: files/admin-gw-root-config.sh.
resource "terraform_data" "admin_gw_tun" {
  for_each = module.admin_gw

  triggers_replace = [
    filesha256("${path.module}/files/admin-gw-root-config.sh"),
    each.value.generation,
  ]

  provisioner "local-exec" {
    command = "${local.node_ssh[each.value.node]} 'bash -s -- ${each.value.vmid}' < ${path.module}/files/admin-gw-root-config.sh"
  }
}

moved {
  from = terraform_data.admin_gw_tun
  to   = terraform_data.admin_gw_tun["admin-gw"]
}
