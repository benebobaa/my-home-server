output "guests" {
  description = "Managed guests: node, VMID, IP."
  value = {
    admin-gw   = { node = module.admin_gw["admin-gw"].node, vmid = module.admin_gw["admin-gw"].vmid, ip = module.admin_gw["admin-gw"].ip }
    admin-gw2  = { node = module.admin_gw["admin-gw2"].node, vmid = module.admin_gw["admin-gw2"].vmid, ip = module.admin_gw["admin-gw2"].ip }
    monitoring = { node = module.monitoring.node, vmid = module.monitoring.vmid, ip = module.monitoring.ip }
    archive = {
      node = proxmox_virtual_environment_container.archive.node_name
      vmid = proxmox_virtual_environment_container.archive.vm_id
      ip   = local.host.archive.ip
    }
  }
}
