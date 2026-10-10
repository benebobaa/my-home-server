# Proxmox firewall — only for the K3s VMs (VLAN 25, tenant code).
#
# The two VMs share a VLAN; without a per-VM firewall the worker (where
# tenant code runs) could claim 10.10.25.20 and pass the Postgres pinhole.
# Each VM gets ipfilter + macfilter: it may only send from its own address
# and MAC. Policies stay ACCEPT — the anti-spoofing is the filter, not the
# policy (DROP would cut flannel, kubelet, the API and the monitoring pings).
# Consequence: these NICs cannot carry a floating address (kube-vip, MetalLB
# L2). Services stay on node IPs (ServiceLB); a VIP needs an ipset entry here.
#
# Order, enforced below: per-VM ipsets and options (inert until the
# datacenter switch is on) → the NICs' firewall flag → the root script that
# turns the hosts' firewalls OFF and the datacenter's ON (files/pve-firewall.sh).
# Hosts and containers are unaffected.
#
# Owner note: this is cluster config in /etc/pve, kept here (not Ansible) so
# one apply orders it; AGENTS.md lists it.

locals {
  k3s_vm_ids = {
    k3s          = proxmox_virtual_environment_vm.k3s.vm_id
    "k3s-worker" = proxmox_virtual_environment_vm.k3s_worker.vm_id
  }
}

# For VMs, PVE does NOT add the configured address implicitly (it does for
# containers): with ipfilter on and no ipset, all IPv4 out of the VM drops.
resource "proxmox_virtual_environment_firewall_ipset" "k3s_ipfilter" {
  for_each = local.k3s_vm_ids

  node_name = local.host[each.key].node
  vm_id     = each.value
  name      = "ipfilter-net0" # must match the NIC id
  comment   = "the only source address ${each.key} may use (managed by OpenTofu)"

  cidr {
    name    = local.host[each.key].ip
    comment = each.key
  }
}

resource "proxmox_virtual_environment_firewall_options" "k3s" {
  for_each = local.k3s_vm_ids

  node_name     = local.host[each.key].node
  vm_id         = each.value
  enabled       = true
  ipfilter      = true
  macfilter     = true
  input_policy  = "ACCEPT"
  output_policy = "ACCEPT"
  dhcp          = false
  ndp           = false
  radv          = false

  depends_on = [proxmox_virtual_environment_firewall_ipset.k3s_ipfilter]
}

# Re-runs when the script or the node set changes: a node that joins later
# (pve1) has no host.fw, so with the datacenter switch on its own firewall
# would default to ON (DROP input) until this sets it off.
resource "terraform_data" "pve_firewall" {
  triggers_replace = [
    filesha256("${path.module}/files/pve-firewall.sh"),
    sort(keys(local.node_ssh)),
  ]

  provisioner "local-exec" {
    command = "${local.node_ssh["pve2"]} 'bash -s' < ${path.module}/files/pve-firewall.sh"
  }

  depends_on = [
    proxmox_virtual_environment_firewall_options.k3s,
    proxmox_virtual_environment_vm.k3s,
    proxmox_virtual_environment_vm.k3s_worker,
  ]
}
