# Loads and validates lab.yaml — the lab's single source of addresses
# (ADR 0007). No providers, no resources, no state: both stacks call it as a
# module, and `make inventory` plans it on its own to run the checks without
# secrets.

terraform {
  required_version = ">= 1.8"
}

locals {
  raw = yamldecode(file("${path.module}/lab.yaml"))

  vlans = {
    for name, v in local.raw.vlans : name => merge(v, {
      name          = name
      dhcp          = try(v.dhcp, false)
      prefix_length = tonumber(split("/", v.cidr)[1])
    })
  }

  hosts = {
    for name, h in local.raw.hosts : name => {
      name       = name
      kind       = h.kind
      vlan       = h.vlan
      vlan_id    = try(local.vlans[h.vlan].id, null)
      ip         = h.ip
      cidr       = "${h.ip}/${try(local.vlans[h.vlan].prefix_length, 32)}"
      gateway    = try(local.vlans[h.vlan].gateway, null)
      vmid       = try(h.vmid, null)
      node       = try(h.node, null)
      cluster_ip = try(h.cluster_ip, null)
      status     = try(h.status, "live")
      dns        = try(h.dns, try(h.status, "live") == "live")
      note       = try(h.note, "")
      monitoring = local.monitoring[name]
    }
  }

  # --- monitoring (the observability standard, ADR 0008) ----------------------
  # `monitoring:` is either a block or the string "none". Normalised so every
  # consumer sees the same shape; `{ip}` in a health URL is the host's IP.
  monitoring = {
    for name, h in local.raw.hosts : name => (
      can(h.monitoring.tier) ? {
        enabled       = true
        tier          = h.monitoring.tier
        health        = try(replace(h.monitoring.health, "{ip}", h.ip), null)
        health_module = try(h.monitoring.health_module, "http_2xx")
        metrics       = [for p in try(h.monitoring.metrics, []) : tonumber(p)]
        logs          = try(h.monitoring.logs, false)
        } : {
        enabled       = false
        tier          = null
        health        = null
        health_module = null
        metrics       = []
        logs          = false
      }
    )
  }

  # TCP ports the monitoring host connects to on each monitored host:
  # metrics ports + the health URL's port. The router stack opens exactly
  # these for hosts outside MGMT.
  monitoring_ports = {
    for name, m in local.monitoring : name => distinct(concat(
      m.metrics,
      m.health == null ? [] : [
        for g in [regex("^(https?)://[^/:]+(?::([0-9]+))?", m.health)] :
        tonumber(coalesce(g[1], g[0] == "https" ? "443" : "80"))
      ],
    ))
  }

  # --- validation: each list names the offenders ------------------------------
  ips   = [for h in local.hosts : h.ip]
  vmids = [for h in local.hosts : h.vmid if h.vmid != null]

  bad_supernet = [for n, v in local.vlans : n if n != "native" && !cidrcontains(local.raw.supernet, cidrhost(v.cidr, 0))]
  bad_vlan     = [for n, h in local.hosts : "${n} (vlan ${h.vlan})" if !contains(keys(local.vlans), h.vlan)]
  bad_subnet   = [for n, h in local.hosts : "${n} (${h.ip} not in ${local.vlans[h.vlan].cidr})" if contains(keys(local.vlans), h.vlan) && !cidrcontains(local.vlans[h.vlan].cidr, h.ip)]
  dup_ips      = distinct([for ip in local.ips : ip if length([for x in local.ips : x if x == ip]) > 1])
  dup_vmids    = distinct([for id in local.vmids : id if length([for x in local.vmids : x if x == id]) > 1])
  bad_kind     = [for n, h in local.hosts : "${n} (${h.kind})" if !contains(["device", "node", "lxc", "vm"], h.kind)]
  bad_status   = [for n, h in local.hosts : "${n} (${h.status})" if !contains(["live", "planned"], h.status)]
  bad_guest    = [for n, h in local.hosts : n if contains(["lxc", "vm"], h.kind) && h.status == "live" && (h.vmid == null || h.node == null)]
  bad_node_ref = [for n, h in local.hosts : "${n} (node ${h.node})" if h.node != null && !contains([for m, x in local.hosts : m if x.kind == "node"], coalesce(h.node, "-"))]

  # Every live host states how it is watched: a block, or `monitoring: none`.
  no_monitoring = [for n, h in local.raw.hosts : n if try(h.status, "live") == "live" && try(h.monitoring, null) == null]
  bad_monitoring = concat(
    [for n, h in local.raw.hosts : "${n} (monitoring must be a block or \"none\")" if try(h.monitoring, null) != null && !can(h.monitoring.tier) && try(h.monitoring == "none", false) == false],
    [for n, m in local.monitoring : "${n} (tier ${m.tier})" if m.enabled && !contains(["critical", "standard", "best-effort"], coalesce(m.tier, "-"))],
    [for n, m in local.monitoring : "${n} (health ${m.health})" if m.health != null && !can(regex("^https?://", coalesce(m.health, "-")))],
    [for n, m in local.monitoring : "${n} (health_module ${m.health_module})" if m.enabled && !contains(["http_2xx", "http_any"], coalesce(m.health_module, "-"))],
    # The DMZ never pushes into MGMT (ADR 0008): monitoring pulls from it.
    [for n, m in local.monitoring : "${n} (logs: true in the DMZ)" if m.logs && try(local.raw.hosts[n].vlan, "") == "dmz"],
  )
}

output "supernet" {
  description = "CIDR that contains every lab VLAN except the native switch segment."
  value       = local.raw.supernet
}

output "vlans" {
  description = "VLANs by name: id, cidr, gateway, prefix_length, note."
  value       = local.vlans

  precondition {
    condition     = length(local.bad_supernet) == 0
    error_message = "lab.yaml: VLAN outside the supernet: ${join(", ", local.bad_supernet)}"
  }
}

output "hosts" {
  description = "Every host by name: kind, vlan, vlan_id, ip, cidr (ip/prefix), gateway, vmid, node, cluster_ip, status, dns, note, monitoring (normalised: enabled, tier, health, health_module, metrics, logs)."
  value       = local.hosts

  precondition {
    condition     = length(local.bad_vlan) == 0
    error_message = "lab.yaml: unknown VLAN: ${join(", ", local.bad_vlan)}"
  }
  precondition {
    condition     = length(local.bad_subnet) == 0
    error_message = "lab.yaml: IP outside its VLAN: ${join(", ", local.bad_subnet)}"
  }
  precondition {
    condition     = length(local.dup_ips) == 0
    error_message = "lab.yaml: duplicate IP: ${join(", ", local.dup_ips)}"
  }
  precondition {
    condition     = length(local.dup_vmids) == 0
    error_message = "lab.yaml: duplicate VMID: ${join(", ", [for v in local.dup_vmids : tostring(v)])}"
  }
  precondition {
    condition     = length(local.bad_kind) == 0 && length(local.bad_status) == 0
    error_message = "lab.yaml: bad kind/status: ${join(", ", concat(local.bad_kind, local.bad_status))}"
  }
  precondition {
    condition     = length(local.bad_guest) == 0 && length(local.bad_node_ref) == 0
    error_message = "lab.yaml: live guests need vmid + node, and node must be a node host: ${join(", ", concat(local.bad_guest, local.bad_node_ref))}"
  }
  precondition {
    condition     = length(local.no_monitoring) == 0
    error_message = "lab.yaml: live host without a monitoring block (add one, or `monitoring: none` with the reason in `note` — docs/standards/observability.md): ${join(", ", local.no_monitoring)}"
  }
  precondition {
    condition     = length(local.bad_monitoring) == 0
    error_message = "lab.yaml: bad monitoring block: ${join(", ", local.bad_monitoring)}"
  }
}

output "monitoring_ports" {
  description = "<name> => TCP ports the monitoring host connects to (metrics ports + the health URL's port)."
  value       = local.monitoring_ports
}

output "dns_records" {
  description = "<name> => ip for every host with dns = true (A records under home.arpa)."
  value       = { for n, h in local.hosts : n => h.ip if h.dns }
}
