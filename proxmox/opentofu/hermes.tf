# hermes — the operator's personal agent (ADR 0018): Hermes Agent with its
# Telegram gateway, in an unprivileged container on pve1, on the LAB VLAN
# (internet only). Online while pve1 is up; Telegram keeps messages sent
# meanwhile for 24 h. Service notes: services/hermes/README.md
#
# No provider resource on pve1 (ADR 0012, as ai.tf): these terraform_data
# resources read nothing remote at plan time and run only when their inputs
# change; such an apply needs pve1 up.
#
#   hermes_ct         create/converge the container (services/hermes/ct.sh)
#   hermes_provision  in-guest setup: Hermes at a pinned release, its service
#   hermes_secrets    bot token, allowed user, model key → ~hermes/.hermes/.env

locals {
  hermes_dir = "${path.module}/../../services/hermes"
  hermes_ssh = local.node_ssh[local.host.hermes.node]
  hermes_files_sha = sha256(join("", [
    for f in sort(fileset(local.hermes_dir, "**")) :
    filesha256("${local.hermes_dir}/${f}") if f != "README.md" && f != "ct.sh"
  ]))
}

resource "terraform_data" "hermes_ct" {
  triggers_replace = [
    filesha256("${local.hermes_dir}/ct.sh"),
    local.host.hermes.vmid,
    local.host.hermes.cidr,
    local.host.hermes.gateway,
    local.host.hermes.vlan_id,
  ]

  provisioner "local-exec" {
    command = "${local.hermes_ssh} 'bash -s -- ${local.host.hermes.vmid} ${local.host.hermes.name} ${local.host.hermes.cidr} ${local.host.hermes.gateway} ${local.host.hermes.vlan_id}' < ${local.hermes_dir}/ct.sh"
  }
}

resource "terraform_data" "hermes_provision" {
  triggers_replace = [local.hermes_files_sha, terraform_data.hermes_ct.id]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md --exclude ct.sh -C ${local.hermes_dir} -cf - . \
        | ${local.hermes_ssh} 'pct exec ${local.host.hermes.vmid} -- sh -c "rm -rf /root/hermes && mkdir -p /root/hermes && tar -xf - -C /root/hermes"'
      ${local.hermes_ssh} 'pct exec ${local.host.hermes.vmid} -- bash /root/hermes/provision.sh'
    EOT
  }
}

# Secrets travel only over the root SSH to pve1 (host key pinned in the
# operator's known_hosts), then `pct exec` into the container, on stdin.
resource "terraform_data" "hermes_secrets" {
  triggers_replace = [
    sha256(join("\n", [
      var.hermes_telegram_bot_token,
      var.hermes_telegram_allowed_users,
      var.hermes_opencode_go_api_key,
    ])),
  ]

  # Re-applied after every provision run (it may rewrite the service).
  lifecycle {
    replace_triggered_by = [terraform_data.hermes_provision]
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\nOPENCODE_GO_API_KEY=%s\n' \
        "$TG_TOKEN" "$TG_USERS" "$OPENCODE_GO_KEY" \
        | ${local.hermes_ssh} 'pct exec ${local.host.hermes.vmid} -- bash /root/hermes/secrets.sh'
    EOT

    environment = {
      TG_TOKEN        = var.hermes_telegram_bot_token
      TG_USERS        = var.hermes_telegram_allowed_users
      OPENCODE_GO_KEY = var.hermes_opencode_go_api_key
    }
  }

  depends_on = [terraform_data.hermes_provision]
}
