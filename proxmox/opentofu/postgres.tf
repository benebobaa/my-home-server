# postgres — the lab's shared PostgreSQL 18: one instance, one database + one
# login role per app (ADR 0010). Service notes: services/postgres/README.md
#
# VLAN 20 (servers) with the apps, on pve2 (stateful-guest placement). Apps
# on VLAN 20 reach 5432 directly (same VLAN, no router hop); pg_hba admits
# them over TLS, by password, to their own database only. Monitoring scrapes
# the exporter on 9187 and the journal ships to `logs` (hEX rules generated
# from lab.yaml).
#
#   postgres_setup  server, config, exporter, nightly dump (services/postgres/setup.sh)
#   postgres_roles  app roles + databases, passwords generated below
#
# An app gets a database by adding its name to postgres_databases; its own .tf
# then delivers random_password.postgres["<name>"].result into its guest (the
# monitoring_secrets pattern) and connects to postgres.home.arpa:5432,
# database = user = <name>, sslmode=require.

locals {
  postgres_dir = "${path.module}/../../services/postgres"
  postgres_ssh = local.node_ssh[local.host.postgres.node]
  postgres_files_sha = sha256(join("", [
    for f in sort(fileset(local.postgres_dir, "**")) :
    filesha256("${local.postgres_dir}/${f}") if f != "README.md"
  ]))
  # The VLAN apps connect from (pg_hba).
  postgres_app_cidr = module.lab.vlans[local.host.postgres.vlan].cidr

  # Apps with a database: name = database = role ([a-z][a-z0-9_]*).
  postgres_databases = toset([])
}

module "postgres" {
  source = "./modules/lxc-guest"

  host             = local.host.postgres
  description      = "postgres — the lab's shared PostgreSQL 18, one database per app (10.10.20.21). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["postgres", "tofu"]
  template_file_id = proxmox_download_file.debian_13_template_pve2.id
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 2
  memory_mb = 2048
  # Data, WAL and the last 3 nightly dumps (services/postgres/dump.sh) on the
  # root disk, so the PBS backup covers all of it. Grow it in place.
  disk_gb = 20
}

resource "terraform_data" "postgres_setup" {
  triggers_replace = [
    local.postgres_files_sha,
    module.postgres.generation,
    local.host.postgres.ip,
    local.postgres_app_cidr,
    local.host.monitoring.ip,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.postgres_dir} -cf - . \
        | ${local.postgres_ssh} 'pct exec ${module.postgres.vmid} -- sh -c "rm -rf /root/postgres && mkdir -p /root/postgres && tar -xf - -C /root/postgres"'
      ${local.postgres_ssh} 'pct exec ${module.postgres.vmid} -- bash /root/postgres/setup.sh ${local.host.postgres.ip} ${local.postgres_app_cidr} ${local.host.monitoring.ip}'
    EOT
  }
}

# One password per app database. Lives only in the (encrypted) state, in
# the postgres CT and in the app's guest. Rotate: tofu apply
# -replace='random_password.postgres["<name>"]' (the app's secret step re-runs too).
resource "random_password" "postgres" {
  for_each = local.postgres_databases

  length  = 32
  special = false
}

resource "terraform_data" "postgres_roles" {
  triggers_replace = [
    sha256(join("\n", [for n in sort(tolist(local.postgres_databases)) : "${n}=${random_password.postgres[n].result}"])),
    filesha256("${local.postgres_dir}/roles.sh"),
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.postgres_setup]
  }

  provisioner "local-exec" {
    command = "printf '%s\\n' \"$ROLES\" | ${local.postgres_ssh} 'pct exec ${module.postgres.vmid} -- bash /root/postgres/roles.sh'"

    environment = {
      ROLES = join("\n", [for n in sort(tolist(local.postgres_databases)) : "${n}=${random_password.postgres[n].result}"])
    }
  }

  depends_on = [terraform_data.postgres_setup]
}
