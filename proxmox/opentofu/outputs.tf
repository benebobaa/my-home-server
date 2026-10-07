output "admin_gw" {
  description = "admin-gw container summary."
  value = {
    node     = proxmox_virtual_environment_container.admin_gw.node_name
    vm_id    = proxmox_virtual_environment_container.admin_gw.vm_id
    hostname = "admin-gw"
    ipv4     = "10.10.10.15"
  }
}
