# pbs-replica — a second Proxmox Backup Server on pve1 (ADR 0025): the copy of
# VM 300, its registry disk included. Same server code as pbs.tf
# (services/pbs; PBS_STORE selects the datastore), its own container and job.
#
#   (template)               the Debian 13 template pve1 already holds
#   module.pbs_replica       CT 112; its root disk is the datastore `replica`
#   pbs_replica_setup        packages, datastore, schedules (services/pbs/setup.sh)
#   pbs_replica_link         PVE storage `pbs-replica` and job `replica-registry`:
#                            VM 300 only, 03:30 (files/pbs-link.sh)

locals {
  pbs_replica_ssh = local.node_ssh[local.host["pbs-replica"].node]
}

module "pbs_replica" {
  source = "./modules/lxc-guest"

  host        = local.host["pbs-replica"]
  description = "pbs-replica — second Proxmox Backup Server on pve1 (10.10.10.19): the copy of VM 300, registry blobs included (ADR 0025). Managed by OpenTofu: proxmox/opentofu."
  tags        = ["pbs", "tofu"]
  # The same template pve1 already holds (pvesm list local --content vztmpl).
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 2
  memory_mb = 2048
  # The datastore lives on the root disk. VM 300 (root 40 GB, registry 40 GB
  # with ~8 GB used) deduplicates well under this; kept 7 daily / 4 weekly /
  # 6 monthly by the prune job the setup creates.
  disk_gb = 150
}

resource "terraform_data" "pbs_replica_setup" {
  triggers_replace = [local.pbs_files_sha, module.pbs_replica.generation]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.pbs_dir} -cf - . \
        | ${local.pbs_replica_ssh} 'pct exec ${module.pbs_replica.vmid} -- sh -c "rm -rf /root/pbs && mkdir -p /root/pbs && tar -xf - -C /root/pbs"'
      ${local.pbs_replica_ssh} 'pct exec ${module.pbs_replica.vmid} -- env PBS_STORE=replica bash /root/pbs/setup.sh'
    EOT
  }
}

# Root-only, on pve1 (the CT's node). The storage and the job are cluster-wide.
resource "terraform_data" "pbs_replica_link" {
  triggers_replace = [
    filesha256("${path.module}/files/pbs-link.sh"),
    module.pbs_replica.generation,
  ]

  provisioner "local-exec" {
    command = "${local.pbs_replica_ssh} 'PBS_STORE=replica PBS_STORAGE=pbs-replica PBS_JOB=replica-registry PBS_SCHEDULE=03:30 PBS_VMIDS=${local.host.k3s.vmid} bash -s -- ${module.pbs_replica.vmid} ${local.host["pbs-replica"].ip}' < ${path.module}/files/pbs-link.sh"
  }

  depends_on = [terraform_data.pbs_replica_setup]
}
