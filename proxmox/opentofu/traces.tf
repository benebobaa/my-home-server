# traces — VictoriaTraces, the lab's trace store (ADR 0026). Service notes:
# services/traces/README.md
#
# CT 122 on pve1: always on with the NVMe disk (ADR 0023), and stateful data
# belongs there beside pbs-replica (ADR 0025). MGMT, beside monitoring and the
# log store, so Grafana reads it without a router rule. Its shipping is
# generic (logs.tf: log_shipping). Senders outside MGMT need one pinhole per
# host on 10428 (ADR 0026); the DMZ never ships into MGMT.

locals {
  traces_dir = "${path.module}/../../services/traces"
  traces_ssh = local.node_ssh[local.host.traces.node]
  traces_files_sha = sha256(join("", [
    for f in sort(fileset(local.traces_dir, "**")) :
    filesha256("${local.traces_dir}/${f}") if f != "README.md"
  ]))
}

module "traces" {
  source = "./modules/lxc-guest"

  host        = local.host.traces
  description = "traces — VictoriaTraces, the lab trace store (10.10.10.20, ADR 0026). Managed by OpenTofu: proxmox/opentofu."
  tags        = ["traces", "tofu"]
  # The same template pve1 already holds (pbs-replica.tf).
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 1
  memory_mb = 1024
  # 30 days of spans (services/traces/setup.sh) + OS.
  disk_gb = 20
}

resource "terraform_data" "traces_setup" {
  triggers_replace = [local.traces_files_sha, module.traces.generation]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.traces_dir} -cf - . \
        | ${local.traces_ssh} 'pct exec ${module.traces.vmid} -- sh -c "rm -rf /root/traces && mkdir -p /root/traces && tar -xf - -C /root/traces"'
      ${local.traces_ssh} 'pct exec ${module.traces.vmid} -- bash /root/traces/setup.sh'
    EOT
  }
}
