# nats — the lab's shared NATS with JetStream: one account per app, each with
# its JetStream limits and one user named after the app (ADR 0016). Service
# notes: services/nats/README.md
#
# VLAN 20 (servers), on pve2 (JetStream is state). Apps on VLAN 20 connect to
# tls://nats.home.arpa:4222; an app outside it runs a leaf node of its own
# that dials 7422 through one exact hEX rule. Monitoring probes 8222/healthz
# and scrapes the exporter on 7777 (hEX rules generated from lab.yaml).
#
#   nats_setup     server, exporter, config (services/nats/setup.sh)
#   nats_tls       the listeners' certificate, generated here (tls.sh)
#   nats_accounts  one account per app; only the bcrypt hashes reach the CT

locals {
  nats_dir = "${path.module}/../../services/nats"
  nats_ssh = local.node_ssh[local.host.nats.node]
  nats_files_sha = sha256(join("", [
    for f in sort(fileset(local.nats_dir, "**")) :
    filesha256("${local.nats_dir}/${f}") if f != "README.md"
  ]))

  # Apps with an account: name = account = user ([a-z][a-z0-9_]*), and their
  # JetStream limits. A stream's max_bytes is reserved against max_file even
  # when empty: Kubeletto's 12 streams reserve 6.3 GB and use ~1 MB. The sum
  # stays under the server's 10 GB (setup.sh).
  nats_accounts = {
    kubeletto = { max_file = "8GB", max_mem = "64MB" }
  }
}

module "nats" {
  source = "./modules/lxc-guest"

  host             = local.host.nats
  description      = "nats — the lab's shared NATS + JetStream, one account per app (10.10.20.22). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["nats", "tofu"]
  template_file_id = local.debian_13_template[local.host.nats.node]
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 1
  memory_mb = 384
  # JetStream's file store. Thin-provisioned: it costs what is written.
  disk_gb = 16
}

resource "terraform_data" "nats_setup" {
  triggers_replace = [
    local.nats_files_sha,
    module.nats.generation,
    local.host.nats.ip,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.nats_dir} -cf - . \
        | ${local.nats_ssh} 'pct exec ${module.nats.vmid} -- sh -c "rm -rf /root/nats && mkdir -p /root/nats && tar -xf - -C /root/nats"'
      ${local.nats_ssh} 'pct exec ${module.nats.vmid} -- bash /root/nats/setup.sh ${local.host.nats.ip}'
    EOT
  }
}

# The listeners' certificate: self-signed, generated here so it survives a
# rebuild of the CT, with the hub's name and IP so a client can pin it (a
# leaf: `tls { ca_file }`, output nats_tls_cert) instead of skipping
# verification. Not secret; the key is (encrypted state, then the CT only).
resource "tls_private_key" "nats" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "nats" {
  private_key_pem = tls_private_key.nats.private_key_pem

  subject {
    common_name = "nats.home.arpa"
  }
  dns_names             = ["nats.home.arpa"]
  ip_addresses          = [local.host.nats.ip]
  validity_period_hours = 24 * 365 * 10
  allowed_uses          = ["digital_signature", "server_auth"]
}

output "nats_tls_cert" {
  description = "The shared NATS's TLS certificate (PEM), for clients and leaf nodes to pin."
  value       = tls_self_signed_cert.nats.cert_pem
}

resource "terraform_data" "nats_tls" {
  triggers_replace = [
    sha256(tls_self_signed_cert.nats.cert_pem),
    filesha256("${local.nats_dir}/tls.sh"),
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.nats_setup]
  }

  provisioner "local-exec" {
    command = "printf '%s\\n%s\\n' \"$CERT\" \"$KEY\" | ${local.nats_ssh} 'pct exec ${module.nats.vmid} -- bash /root/nats/tls.sh'"

    environment = {
      CERT = tls_self_signed_cert.nats.cert_pem
      KEY  = tls_private_key.nats.private_key_pem
    }
  }

  depends_on = [terraform_data.nats_setup]
}

# One password per app account. The CT gets only its bcrypt hash; the app
# gets the password (its own .tf or deploy, like the Postgres passwords).
# Rotate: tofu apply -replace='random_password.nats["<app>"]', then the app.
resource "random_password" "nats" {
  for_each = local.nats_accounts

  length  = 32
  special = false
}

resource "terraform_data" "nats_accounts" {
  triggers_replace = [
    sha256(join("\n", [for n in sort(keys(local.nats_accounts)) : "${n} ${random_password.nats[n].bcrypt_hash} ${local.nats_accounts[n].max_file} ${local.nats_accounts[n].max_mem}"])),
    filesha256("${local.nats_dir}/accounts.sh"),
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.nats_setup]
  }

  provisioner "local-exec" {
    command = "printf '%s\\n' \"$ACCOUNTS\" | ${local.nats_ssh} 'pct exec ${module.nats.vmid} -- bash /root/nats/accounts.sh'"

    environment = {
      ACCOUNTS = join("\n", [for n in sort(keys(local.nats_accounts)) : "${n} ${random_password.nats[n].bcrypt_hash} ${local.nats_accounts[n].max_file} ${local.nats_accounts[n].max_mem}"])
    }
  }

  depends_on = [terraform_data.nats_setup, terraform_data.nats_tls]
}
