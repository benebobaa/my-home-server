# Addresses come from inventory/lab.yaml (ADR 0007) — never typed here.
module "lab" {
  source = "../../inventory"
}

locals {
  vlan     = module.lab.vlans
  host     = module.lab.hosts
  supernet = module.lab.supernet

  # The hEX's own address on each VLAN: "<gateway>/<prefix>".
  gw_cidr = { for k, v in local.vlan : k => "${v.gateway}/${v.prefix_length}" if v.gateway != null }

  # DHCP pools on the VLANs with dhcp: true: .100-.199 by convention (lab.yaml).
  dhcp_range = { for k, v in local.vlan : k => "${cidrhost(v.cidr, 100)}-${cidrhost(v.cidr, 199)}" if v.dhcp }
}
