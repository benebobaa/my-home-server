# valkey — the lab's shared Valkey: one instance (process, TLS port,
# password, memory cap, exporter) per app (ADR 0016). Service notes:
# services/valkey/README.md
#
# VLAN 20 (servers), on pve3: a cache, nothing to keep, so off pve2's CPU.
# Apps connect to rediss://:<password>@valkey.home.arpa:<port>/0 and pin the
# certificate (output valkey_tls_cert; ADR 0017). Monitoring scrapes each instance's
# exporter (hEX rules generated from lab.yaml's metrics list).
#
#   valkey_setup      packages, exporter unit (services/valkey/setup.sh)
#   valkey_tls        the instances' certificate, generated here (tls.sh)
#   valkey_instances  one instance per app, passwords on stdin

locals {
  valkey_dir = "${path.module}/../../services/valkey"
  valkey_ssh = local.node_ssh[local.host.valkey.node]
  valkey_files_sha = sha256(join("", [
    for f in sort(fileset(local.valkey_dir, "**")) :
    filesha256("${local.valkey_dir}/${f}") if f != "README.md"
  ]))

  # Apps with an instance. port from 6380, exporter from 9121; every exporter
  # port must be in lab.yaml's `valkey` metrics list (checked below), or
  # nothing scrapes it and the hEX drops the scrape.
  valkey_instances = {
    kubeletto   = { port = 6380, exporter_port = 9121, maxmemory = "96mb", policy = "volatile-lru" }
    larasrouter = { port = 6381, exporter_port = 9122, maxmemory = "64mb", policy = "volatile-lru" }
  }
}

module "valkey" {
  source = "./modules/lxc-guest"

  host             = local.host.valkey
  description      = "valkey — the lab's shared Valkey, one instance per app (10.10.20.23). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["valkey", "tofu"]
  template_file_id = local.debian_13_template[local.host.valkey.node]
  ssh_public_key   = local.admin_ssh_public_key

  cores = 1
  # The instances' maxmemory plus Valkey and the exporters; pve3 has ~1.4 GB.
  memory_mb = 256
  disk_gb   = 4
}

resource "terraform_data" "valkey_setup" {
  triggers_replace = [
    local.valkey_files_sha,
    module.valkey.generation,
    local.host.monitoring.ip,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.valkey_dir} -cf - . \
        | ${local.valkey_ssh} 'pct exec ${module.valkey.vmid} -- sh -c "rm -rf /root/valkey && mkdir -p /root/valkey && tar -xf - -C /root/valkey"'
      ${local.valkey_ssh} 'pct exec ${module.valkey.vmid} -- bash /root/valkey/setup.sh ${local.host.monitoring.ip}'
    EOT
  }
}

# The instances' certificate: self-signed, generated here so it survives a
# rebuild of the CT, with the CT's name and IP so clients pin it (output
# valkey_tls_cert; Kubeletto: REDIS_TLS_CA) instead of skipping verification
# (ADR 0017).
resource "tls_private_key" "valkey" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "valkey" {
  private_key_pem = tls_private_key.valkey.private_key_pem

  subject {
    common_name = "valkey.home.arpa"
  }
  dns_names             = ["valkey.home.arpa"]
  ip_addresses          = [local.host.valkey.ip]
  validity_period_hours = 24 * 365 * 10
  allowed_uses          = ["digital_signature", "server_auth"]
}

output "valkey_tls_cert" {
  description = "The shared Valkey's TLS certificate (PEM), for clients to pin."
  value       = tls_self_signed_cert.valkey.cert_pem
}

resource "terraform_data" "valkey_tls" {
  triggers_replace = [
    sha256(tls_self_signed_cert.valkey.cert_pem),
    filesha256("${local.valkey_dir}/tls.sh"),
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.valkey_setup]
  }

  provisioner "local-exec" {
    command = "printf '%s\\n%s\\n' \"$CERT\" \"$KEY\" | ${local.valkey_ssh} 'pct exec ${module.valkey.vmid} -- bash /root/valkey/tls.sh'"

    environment = {
      CERT = tls_self_signed_cert.valkey.cert_pem
      KEY  = tls_private_key.valkey.private_key_pem
    }
  }

  depends_on = [terraform_data.valkey_setup]
}

# One password per instance. Rotate: tofu apply
# -replace='random_password.valkey["<app>"]', then the app.
resource "random_password" "valkey" {
  for_each = local.valkey_instances

  length  = 32
  special = false
}

resource "terraform_data" "valkey_instances" {
  triggers_replace = [
    sha256(join("\n", [for n in sort(keys(local.valkey_instances)) : "${n} ${jsonencode(local.valkey_instances[n])} ${random_password.valkey[n].result}"])),
    filesha256("${local.valkey_dir}/instances.sh"),
    local.host.valkey.ip,
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.valkey_setup]

    precondition {
      condition     = alltrue([for i in values(local.valkey_instances) : contains(local.host.valkey.monitoring.metrics, i.exporter_port)])
      error_message = "Every valkey exporter_port must be listed in inventory/lab.yaml under valkey.monitoring.metrics."
    }
  }

  provisioner "local-exec" {
    command = "printf '%s\\n' \"$INSTANCES\" | ${local.valkey_ssh} 'pct exec ${module.valkey.vmid} -- bash /root/valkey/instances.sh ${local.host.valkey.ip}'"

    environment = {
      INSTANCES = join("\n", [for n in sort(keys(local.valkey_instances)) : "${n} ${local.valkey_instances[n].port} ${local.valkey_instances[n].exporter_port} ${local.valkey_instances[n].maxmemory} ${local.valkey_instances[n].policy} ${random_password.valkey[n].result}"])
    }
  }

  depends_on = [terraform_data.valkey_setup, terraform_data.valkey_tls]
}
