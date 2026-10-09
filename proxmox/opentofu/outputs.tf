output "guests" {
  description = "Managed guests: node, VMID, IP."
  value = {
    admin-gw   = { node = module.admin_gw.node, vmid = module.admin_gw.vmid, ip = module.admin_gw.ip }
    monitoring = { node = module.monitoring.node, vmid = module.monitoring.vmid, ip = module.monitoring.ip }
    archive = {
      node = proxmox_virtual_environment_container.archive.node_name
      vmid = proxmox_virtual_environment_container.archive.vm_id
      ip   = local.host.archive.ip
    }
  }
}
