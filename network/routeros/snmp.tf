# SNMP for the lab monitoring (Prometheus snmp_exporter in CT 120,
# 10.10.10.16 — services/monitoring/). Read-only SNMPv3 with auth + privacy,
# one user, answering only the monitoring host; the input chain admits UDP 161
# from that host alone (firewall.tf, input_snmp_monitoring).
#
# The SNMPv3 username is the community name. The same two passwords are in
# proxmox/opentofu/secrets.sops.env (snmp_exporter's side): rotate both
# together (docs/runbooks/secrets.md).

variable "snmp_auth_password" {
  description = "SNMPv3 authentication (SHA1) password for the monitoring user (from secrets.sops.env)."
  type        = string
  sensitive   = true
}

variable "snmp_priv_password" {
  description = "SNMPv3 privacy (AES) password for the monitoring user (from secrets.sops.env)."
  type        = string
  sensitive   = true
}

resource "routeros_snmp" "this" {
  enabled  = true
  contact  = "homelab operator"
  location = "home rack"
  # No trap_target: the factory trap generator has nowhere to send.
}

resource "routeros_snmp_community" "monitoring" {
  name                    = "monitoring"
  addresses               = ["${local.host.monitoring.ip}/32"]
  security                = "private"
  authentication_protocol = "SHA1"
  authentication_password = var.snmp_auth_password
  encryption_protocol     = "AES"
  encryption_password     = var.snmp_priv_password
  read_access             = true
  write_access            = false
  comment                 = "Prometheus snmp_exporter (CT 120 monitoring)"
}

# The factory "public" community (v1/v2c, no password, any address) cannot be
# deleted; adopt it and switch it off so enabling SNMP exposes nothing else.
import {
  to = routeros_snmp_community.public_default
  id = "*0"
}

resource "routeros_snmp_community" "public_default" {
  name         = "public"
  disabled     = true
  read_access  = false
  write_access = false
  addresses    = ["127.0.0.1/32"]
  comment      = "factory default, disabled (managed by OpenTofu)"
}
