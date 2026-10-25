# Proxmox firewall — only for the K3s VMs (VLAN 25, tenant code).
#
# The two VMs share a VLAN; without a per-VM firewall the worker (where
# tenant code runs) could claim 10.10.25.20 and pass the Postgres pinhole.
# Each VM gets ipfilter + macfilter: it may only send from its own address
# and MAC.
#
# Inbound is allow-listed (2026-10-15; docs/design/kubeletto-architecture.md
# weakness 1): before it, a compromised worker could reach the server's
# kubelet (10250) and node exporter. The list is what conntrack showed
# arriving on both VMs, and nothing more: VXLAN both ways, the worker to the
# API, the server to the worker's kubelet, the monitoring host's scrapes
# (ports from lab.yaml) and pings. Replies to the VMs' own connections pass
# (the firewall is stateful). k3s_input_policy is the switch: "ACCEPT" turns
# the allow-list off; by hand, instantly:
#   pvesh set /nodes/<node>/qemu/<vmid>/firewall/options --policy_in ACCEPT
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
  # Inbound allow-list per K3s VM (see the header). Rollback: ACCEPT.
  k3s_input_policy = {
    k3s          = "DROP"
    "k3s-worker" = "DROP"
  }
  k3s_inbound = {
    k3s = [
      { source = local.host["k3s-worker"].ip, proto = "tcp", dport = "6443", comment = "worker: API server and agent tunnel" },
      { source = local.host["k3s-worker"].ip, proto = "udp", dport = "8472", comment = "worker: flannel VXLAN" },
    ]
    "k3s-worker" = [
      { source = local.host.k3s.ip, proto = "tcp", dport = "10250", comment = "server: kubelet (logs, exec, metrics)" },
      { source = local.host.k3s.ip, proto = "udp", dport = "8472", comment = "server: flannel VXLAN" },
    ]
  }

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
  input_policy  = local.k3s_input_policy[each.key]
  log_level_in  = "info" # drops (e.g. the worker probing the server) in the host's /var/log/pve-firewall.log
  output_policy = "ACCEPT"
  dhcp          = false
  ndp           = false
  radv          = false

  # The allow-list exists before a DROP policy can take effect.
  depends_on = [
    proxmox_virtual_environment_firewall_ipset.k3s_ipfilter,
    proxmox_virtual_environment_firewall_rules.k3s,
  ]
}

# Re-runs when the script or the node set changes: a node that joins later
# (pve1) has no host.fw, so with the datacenter switch on its own firewall
# would default to ON (DROP input) until this sets it off.
resource "proxmox_virtual_environment_firewall_rules" "k3s" {
  for_each = local.k3s_vm_ids

  node_name = local.host[each.key].node
  vm_id     = each.value

  dynamic "rule" {
    for_each = local.k3s_inbound[each.key]
    content {
      type    = "in"
      action  = "ACCEPT"
      source  = rule.value.source
      proto   = rule.value.proto
      dport   = rule.value.dport
      comment = rule.value.comment
    }
  }

  # The monitoring host: the scrape and health ports lab.yaml declares, and
  # ping (blackbox ICMP).
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.host.monitoring.ip
    proto   = "tcp"
    dport   = join(",", [for p in module.lab.monitoring_ports[each.key] : tostring(p)])
    comment = "monitoring: scrape and health (lab.yaml)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.host.monitoring.ip
    proto   = "icmp"
    comment = "monitoring: ping"
  }
}

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
