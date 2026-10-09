output "vmid" {
  description = "PVE VMID."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "node" {
  description = "Node the guest runs on."
  value       = proxmox_virtual_environment_container.this.node_name
}

output "ip" {
  description = "Static IPv4 address (no prefix)."
  value       = split("/", var.host.cidr)[0]
}

# PVE generates the MAC when the container is created: it changes on
# recreation and on nothing else. Key provisioning on this, not on the
# container resource (replace_triggered_by on the resource also fires on
# in-place updates, e.g. a stopped CT flipping `started`).
output "generation" {
  description = "Changes only when the container is recreated (its generated MAC address)."
  value       = proxmox_virtual_environment_container.this.network_interface[0].mac_address
}
