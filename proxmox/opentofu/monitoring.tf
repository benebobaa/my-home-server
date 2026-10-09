# monitoring — Prometheus + Alertmanager + Grafana and the exporters, for the
# whole lab. Why this stack and where: docs/decisions/0006-monitoring-stack.md
# Service notes: services/monitoring/README.md
#
# VLAN 10 (MGMT), like PBS: it scrapes the nodes on their MGMT addresses with
# no router hop. The hEX lets it poll SNMP and ping the other VLANs + switch
# (network/routeros: address-list "monitoring", snmp.tf). On pve2: it holds
# 30 days of metrics (stateful-guest placement rule).
#
# Everything in the guest is converged through the pinned root SSH to pve2 +
# `pct exec` — never a direct SSH to the CT, whose host key changes on every
# rebuild:
#   monitoring_setup     packages + configs (re-runs when services/monitoring/ changes)
#   monitoring_pve_token read-only PVE API token, created on pve2, straight into the CT
#   monitoring_secrets   Telegram, healthchecks.io, SNMPv3, Grafana admin (+ PVE's
#                        own notifications → the same Telegram chat)

locals {
  monitoring_dir = "${path.module}/../../services/monitoring"
  monitoring_ssh = local.node_ssh[local.host.monitoring.node]
  # Everything the guest runs, so an edit to any of it re-converges.
  monitoring_files_sha = sha256(join("", [
    for f in sort(fileset(local.monitoring_dir, "**")) :
    filesha256("${local.monitoring_dir}/${f}") if f != "README.md"
  ]))
}

module "monitoring" {
  source = "./modules/lxc-guest"

  host             = local.host.monitoring
  description      = "monitoring — Prometheus, Alertmanager, Grafana + exporters (10.10.10.16). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["monitoring", "tofu"]
  template_file_id = proxmox_download_file.debian_13_template_pve2.id
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 2
  memory_mb = 1536
  # 30-day TSDB capped at 8 GB (services/monitoring/setup.sh) + OS + Grafana.
  disk_gb = 12
}

moved {
  from = proxmox_virtual_environment_container.monitoring
  to   = module.monitoring.proxmox_virtual_environment_container.this
}

# Packages + configs. Streams services/monitoring/ into the CT and runs
# setup.sh there (idempotent; promtool-checks the config before restarting).
resource "terraform_data" "monitoring_setup" {
  triggers_replace = [local.monitoring_files_sha, module.monitoring.generation]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.monitoring_dir} -cf - . \
        | ${local.monitoring_ssh} 'pct exec ${module.monitoring.vmid} -- sh -c "rm -rf /root/monitoring && mkdir -p /root/monitoring && tar -xf - -C /root/monitoring"'
      ${local.monitoring_ssh} 'pct exec ${module.monitoring.vmid} -- bash /root/monitoring/setup.sh'
    EOT
  }
}

# Read-only PVE API token for prometheus-pve-exporter (root-only: ACLs).
resource "terraform_data" "monitoring_pve_token" {
  triggers_replace = [
    filesha256("${path.module}/files/monitoring-pve-token.sh"),
    module.monitoring.generation,
  ]

  provisioner "local-exec" {
    command = "${local.monitoring_ssh} 'bash -s -- ${module.monitoring.vmid}' < ${path.module}/files/monitoring-pve-token.sh"
  }

  depends_on = [terraform_data.monitoring_setup]
}

# Secrets travel only over the root SSH to pve2 (host key pinned in the
# operator's known_hosts), then `pct exec` into the CT.
resource "terraform_data" "monitoring_secrets" {
  triggers_replace = [
    sha256(join("\n", [
      var.monitoring_telegram_bot_token,
      var.monitoring_telegram_chat_id,
      var.monitoring_healthchecks_ping_url,
      var.monitoring_grafana_admin_password,
      var.monitoring_snmp_auth_password,
      var.monitoring_snmp_priv_password,
    ])),
    filesha256("${local.monitoring_dir}/secrets.sh"),
    filesha256("${local.monitoring_dir}/alertmanager/alertmanager.yml"),
    filesha256("${path.module}/files/monitoring-pve-notify.sh"),
  ]

  # Re-render after every setup run (it replaces /root/monitoring).
  lifecycle {
    replace_triggered_by = [terraform_data.monitoring_setup]
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\nHEALTHCHECKS_PING_URL=%s\nGRAFANA_ADMIN_PASSWORD=%s\nSNMP_AUTH_PASSWORD=%s\nSNMP_PRIV_PASSWORD=%s\n' \
        "$TG_TOKEN" "$TG_CHAT" "$HC_URL" "$GRAFANA_PW" "$SNMP_AUTH" "$SNMP_PRIV" \
        | ${local.monitoring_ssh} 'pct exec ${module.monitoring.vmid} -- bash /root/monitoring/secrets.sh'
      tmp=$(${local.monitoring_ssh} mktemp)
      ${local.monitoring_ssh} "cat > $tmp" < ${path.module}/files/monitoring-pve-notify.sh
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$TG_TOKEN" "$TG_CHAT" \
        | ${local.monitoring_ssh} "bash $tmp; rc=\$?; rm -f $tmp; exit \$rc"
    EOT

    environment = {
      TG_TOKEN   = var.monitoring_telegram_bot_token
      TG_CHAT    = var.monitoring_telegram_chat_id
      HC_URL     = var.monitoring_healthchecks_ping_url
      GRAFANA_PW = var.monitoring_grafana_admin_password
      SNMP_AUTH  = var.monitoring_snmp_auth_password
      SNMP_PRIV  = var.monitoring_snmp_priv_password
    }
  }

  depends_on = [terraform_data.monitoring_setup]
}
