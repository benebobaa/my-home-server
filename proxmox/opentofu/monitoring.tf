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

  # --- scrape targets, generated from the `monitoring:` blocks in lab.yaml ----
  # (ADR 0008). One file_sd file per job; Prometheus re-reads them on change,
  # so adding a host is a targets push, not a setup run. Every target carries
  # `instance` (the inventory name) and `tier` (drives alert severity), and
  # `node` where it has one (the Proxmox node it runs on, or itself for a
  # node): a node that is down then explains its own and its guests' alerts
  # (Alertmanager inhibition), which keeps an on-demand node quiet (ADR 0012).
  watched = { for n, h in local.host : n => h if h.status == "live" && h.monitoring.enabled }
  # Zones that run untrusted code (ADR 0013, 0014): the DMZ (Kubeletto
  # tenants) and the LAB (the `ai` workstation: pip, model hubs, GitHub).
  untrusted_vlans = ["dmz", "lab"]
  target_labels = {
    for n, h in local.watched : n => merge(
      { instance = n, tier = h.monitoring.tier },
      h.kind == "node" ? { node = n } : h.node != null ? { node = h.node } : {},
    )
  }
  # The node that hosts monitoring serves the cluster-wide PVE series; the
  # others only their node config (otherwise every series is doubled).
  pve_cluster_node = local.host.monitoring.node

  scrape_targets = {
    icmp = [for n, h in local.watched : {
      targets = [h.ip]
      labels  = local.target_labels[n]
    }]
    # Untrusted zones (DMZ, LAB) give untrusted answers: their health URLs
    # use the http_dmz module (no redirects, capped body — a redirect would
    # turn the probe into a request into MGMT) and their metrics go to the
    # service_dmz job (sample, label and body limits). The names say "dmz"
    # for history: alert rules match on job="service_dmz".
    http = [for n, h in local.watched : {
      targets = [h.monitoring.health]
      labels = merge(local.target_labels[n], {
        __param_module = contains(local.untrusted_vlans, h.vlan) ? "http_dmz" : h.monitoring.health_module
      })
    } if h.monitoring.health != null]
    service = [for n, h in local.watched : {
      targets = [for p in h.monitoring.metrics : "${h.ip}:${p}"]
      labels  = merge(local.target_labels[n], { service = n })
    } if length(h.monitoring.metrics) > 0 && !contains(local.untrusted_vlans, h.vlan)]
    service_dmz = [for n, h in local.watched : {
      targets = [for p in h.monitoring.metrics : "${h.ip}:${p}"]
      labels  = merge(local.target_labels[n], { service = n })
    } if length(h.monitoring.metrics) > 0 && contains(local.untrusted_vlans, h.vlan)]
    # Proxmox nodes: node_exporter (Ansible `monitoring` tag) + the PVE API.
    node = [for n, h in local.watched : {
      targets = ["${h.ip}:9100"]
      labels  = local.target_labels[n]
    } if h.kind == "node"]
    # No `node` target label here: the exporter's own `node` (where a guest
    # runs) must survive; a target label would rename it `exported_node`.
    # Its TargetDown is still explained by HostUnreachable (same instance).
    pve = [for n, h in local.watched : {
      targets = [h.ip]
      labels = {
        instance        = n
        tier            = h.monitoring.tier
        __param_cluster = n == local.pve_cluster_node ? "1" : "0"
        __param_node    = "1"
      }
    } if h.kind == "node"]
    # The hEX: SNMPv3 (network/routeros/snmp.tf) and its resolver.
    snmp = [{ targets = [local.host.hex.ip], labels = { instance = "hex", tier = local.host.hex.monitoring.tier } }]
    dns  = [{ targets = [local.host.hex.ip], labels = { instance = "hex", tier = local.host.hex.monitoring.tier } }]
  }
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

# Scrape targets → /etc/prometheus/targets/<job>.json (targets.sh). Keyed on
# the generated content, so editing lab.yaml re-pushes them.
resource "terraform_data" "monitoring_targets" {
  triggers_replace = [sha256(jsonencode(local.scrape_targets)), module.monitoring.generation]

  provisioner "local-exec" {
    command = "${local.monitoring_ssh} 'pct exec ${module.monitoring.vmid} -- python3 /root/monitoring/targets.py' <<'JSON'\n${jsonencode(local.scrape_targets)}\nJSON"
  }

  # setup.sh replaces /root/monitoring (where targets.py lives).
  depends_on = [terraform_data.monitoring_setup]
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
