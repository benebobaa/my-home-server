# pbs — Proxmox Backup Server: nightly backups of every guest (ADR 0009).
# Service notes: services/pbs/README.md
#
# On pve3, deliberately: every stateful guest lives on pve2, so its backups
# must not. pve3 normally takes only stateless guests (no-name SSD); a backup
# datastore is the exception, because losing it loses no original data,
# while losing pve2 without it loses everything. The datastore is the CT's
# root disk; when a disk goes into pve3's empty bay it moves there (README).
#
#   pbs_setup  packages, datastore, prune/GC/verify schedules (services/pbs/setup.sh)
#   pbs_link   root-only, on pve3: the PBS token for the cluster, the `pbs`
#              storage entry and the nightly backup job (files/pbs-link.sh)
#   pbs_notify PBS's own job failures (verify, prune, GC) → the Telegram chat

locals {
  pbs_dir = "${path.module}/../../services/pbs"
  pbs_ssh = local.node_ssh[local.host.pbs.node]
  pbs_files_sha = sha256(join("", [
    for f in sort(fileset(local.pbs_dir, "**")) :
    filesha256("${local.pbs_dir}/${f}") if f != "README.md"
  ]))
}

module "pbs" {
  source = "./modules/lxc-guest"

  host             = local.host.pbs
  description      = "pbs — Proxmox Backup Server, nightly backups of every guest (10.10.10.14). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["pbs", "tofu"]
  template_file_id = local.debian_13_template[local.host.pbs.node]
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 2
  memory_mb = 1536
  # The datastore lives on the root disk: ~7.5 GB of guests today,
  # deduplicated and compressed, kept 7 daily / 4 weekly / 6 monthly.
  disk_gb = 30
}

resource "terraform_data" "pbs_setup" {
  triggers_replace = [local.pbs_files_sha, module.pbs.generation]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.pbs_dir} -cf - . \
        | ${local.pbs_ssh} 'pct exec ${module.pbs.vmid} -- sh -c "rm -rf /root/pbs && mkdir -p /root/pbs && tar -xf - -C /root/pbs"'
      ${local.pbs_ssh} 'pct exec ${module.pbs.vmid} -- bash /root/pbs/setup.sh'
    EOT
  }
}

# Root-only (pveum/pvesm/backup jobs), through the pinned root SSH to pve3.
# The PBS token secret goes from the CT straight into the cluster's storage
# config and never leaves the cluster.
resource "terraform_data" "pbs_link" {
  triggers_replace = [
    filesha256("${path.module}/files/pbs-link.sh"),
    module.pbs.generation,
  ]

  provisioner "local-exec" {
    command = "${local.pbs_ssh} 'bash -s -- ${module.pbs.vmid} ${local.host.pbs.ip}' < ${path.module}/files/pbs-link.sh"
  }

  depends_on = [terraform_data.pbs_setup]
}

resource "terraform_data" "pbs_notify" {
  triggers_replace = [
    sha256(join("\n", [var.monitoring_telegram_bot_token, var.monitoring_telegram_chat_id])),
    filesha256("${local.pbs_dir}/notify.sh"),
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.pbs_setup]
  }

  provisioner "local-exec" {
    command = <<-EOT
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$TG_TOKEN" "$TG_CHAT" \
        | ${local.pbs_ssh} 'pct exec ${module.pbs.vmid} -- bash /root/pbs/notify.sh'
    EOT

    environment = {
      TG_TOKEN = var.monitoring_telegram_bot_token
      TG_CHAT  = var.monitoring_telegram_chat_id
    }
  }

  depends_on = [terraform_data.pbs_setup]
}
