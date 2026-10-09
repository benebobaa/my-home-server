# logs — VictoriaLogs, the lab's log store, and the log shipping of every
# container (ADR 0008). Service notes: services/logs/README.md
#
# VLAN 10 (MGMT) beside monitoring, on pve2 (stateful-guest placement: 30
# days of logs). Its own container, not CT 120: log volume is driven by apps
# that do not exist yet, and a flood must never starve Prometheus and
# alerting of disk or memory.
#
# Senders reach it on 9428 (journald upload). From MGMT that is the same
# VLAN; from VLAN 20 the hEX opens it per host (network/routeros,
# forward_logs_ingest). The DMZ never ships into MGMT (lab.yaml refuses
# `logs: true` there). The hEX sends syslog to 5514/udp.

locals {
  logs_dir = "${path.module}/../../services/logs"
  logs_ssh = local.node_ssh[local.host.logs.node]
  logs_files_sha = sha256(join("", [
    for f in sort(fileset(local.logs_dir, "**")) :
    filesha256("${local.logs_dir}/${f}") if f != "README.md"
  ]))
  logs_journald_url = "http://${local.host.logs.ip}:9428/insert/journald"

  # Containers that ship their journal: `logs: true` in lab.yaml. Each needs
  # its recreation marker here, so shipping is set up again on a rebuild —
  # a new container that is missing from this map fails the plan.
  guest_generation = merge(
    { for k, m in module.admin_gw : k => m.generation },
    {
      monitoring = module.monitoring.generation
      logs       = module.logs.generation
      archive    = proxmox_virtual_environment_container.archive.network_interface[0].mac_address
    },
  )
  log_shippers = {
    for n, h in local.host : n => h
    if h.kind == "lxc" && h.status == "live" && h.monitoring.logs
  }
}

module "logs" {
  source = "./modules/lxc-guest"

  host             = local.host.logs
  description      = "logs — VictoriaLogs, the lab log store (10.10.10.18). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["logs", "tofu"]
  template_file_id = proxmox_download_file.debian_13_template_pve2.id
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 1
  memory_mb = 512
  # 6 GiB log cap (services/logs/setup.sh) + OS.
  disk_gb = 10
}

resource "terraform_data" "logs_setup" {
  triggers_replace = [local.logs_files_sha, module.logs.generation]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.logs_dir} -cf - . \
        | ${local.logs_ssh} 'pct exec ${module.logs.vmid} -- sh -c "rm -rf /root/logs && mkdir -p /root/logs && tar -xf - -C /root/logs"'
      ${local.logs_ssh} 'pct exec ${module.logs.vmid} -- bash /root/logs/setup.sh'
    EOT
  }
}

# journald → VictoriaLogs in every shipping container (services/logs/ship.sh).
resource "terraform_data" "log_shipping" {
  for_each = local.log_shippers

  triggers_replace = [
    filesha256("${local.logs_dir}/ship.sh"),
    local.logs_journald_url,
    local.guest_generation[each.key],
  ]

  provisioner "local-exec" {
    command = "${local.node_ssh[each.value.node]} 'pct exec ${each.value.vmid} -- bash -s -- ${local.logs_journald_url}' < ${local.logs_dir}/ship.sh"
  }

  depends_on = [terraform_data.logs_setup]
}
