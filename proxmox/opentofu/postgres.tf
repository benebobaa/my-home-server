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
  postgres_databases = toset(["kubeletto", "larasrouter"])

  # Clients outside the servers VLAN, each to its own database only (pg_hba
  # hostssl line). The hEX pinhole for each is in network/routeros.
  #   kubeletto  its K3s VM in the DMZ (forward_k3s_postgres; ADR 0004, 0010)
  #   larasrouter  the K3s worker VM in the DMZ, where tenant pods run (the
  #                tenant's own NetworkPolicy in kl-f42a6fae-f42a6fae lets only
  #                that namespace send; forward_worker_postgres, ADR 0022)
  postgres_extra_clients = {
    kubeletto   = "${local.host.k3s.ip}/32"
    larasrouter = "${local.host["k3s-worker"].ip}/32"
  }
  postgres_extra_clients_arg = join(",", [for db, cidr in local.postgres_extra_clients : "${db}=${cidr}"])

  # People with read-only access to an app's database (ADR 0029). Each gets a
  # login role `<db>_<handle>` in the group `<db>_read` (readers.sh). Handles
  # are not names (this repo is public); who is who sits next to their
  # Tailscale login in network/tailscale/identities.sops.env. They come in
  # only through the admin gateways, so pg_hba admits the group from those two
  # addresses, and the tailnet policy decides who reaches the gateways' route.
  # `hidden` columns are never readable: credentials, hashes of them, and
  # larasrouter's email outbox payload, which carries the raw password-reset
  # and verification links.
  postgres_readers = {
    larasrouter = {
      people = ["reader1"]
      hidden = [
        "users.password_hash",
        "email_outbox.payload",
        "sessions.token_hash",
        "api_keys.key_hash",
        "password_reset_tokens.token_hash",
        "email_verification_tokens.token_hash",
      ]
    }
  }
  postgres_reader_logins = {
    for pair in flatten([for db, r in local.postgres_readers : [for p in r.people : { login = "${db}_${p}", db = db }]]) :
    pair.login => pair.db
  }
  postgres_readers_hba_arg = join(",", flatten([
    for db in keys(local.postgres_readers) : [for gw in ["admin-gw", "admin-gw2"] : "${db}=${local.host[gw].ip}/32"]
  ]))
  postgres_readers_args = join(" ", [for db, r in local.postgres_readers : "${db}=${join(",", r.hidden)}"])
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
    local.postgres_extra_clients_arg,
    local.postgres_readers_hba_arg,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.postgres_dir} -cf - . \
        | ${local.postgres_ssh} 'pct exec ${module.postgres.vmid} -- sh -c "rm -rf /root/postgres && mkdir -p /root/postgres && tar -xf - -C /root/postgres"'
      ${local.postgres_ssh} 'pct exec ${module.postgres.vmid} -- bash /root/postgres/setup.sh ${local.host.postgres.ip} ${local.postgres_app_cidr} ${local.host.monitoring.ip} ${local.postgres_extra_clients_arg} ${local.postgres_readers_hba_arg}'
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

# One password per reader, like the apps'. It reaches the person through the
# operator (services/larasrouter/urls.sh reader <login>), never the repo.
# Rotate: tofu apply -replace='random_password.postgres_reader["<login>"]'.
resource "random_password" "postgres_reader" {
  for_each = local.postgres_reader_logins

  length  = 32
  special = false
}

resource "terraform_data" "postgres_readers" {
  triggers_replace = [
    sha256(join("\n", [for l in sort(keys(local.postgres_reader_logins)) : "${l}=${random_password.postgres_reader[l].result}"])),
    local.postgres_readers_args,
    filesha256("${local.postgres_dir}/readers.sh"),
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.postgres_roles]
  }

  provisioner "local-exec" {
    command = "printf '%s\\n' \"$READERS\" | ${local.postgres_ssh} 'pct exec ${module.postgres.vmid} -- bash /root/postgres/readers.sh ${local.postgres_readers_args}'"

    environment = {
      READERS = join("\n", [for l, db in local.postgres_reader_logins : "${db} ${l} ${random_password.postgres_reader[l].result}"])
    }
  }

  depends_on = [terraform_data.postgres_roles]
}
