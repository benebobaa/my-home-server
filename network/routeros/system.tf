# --- clock -----------------------------------------------------------------------
# The hEX has no battery-backed RTC: after a power cut it boots with a wrong
# clock until NTP syncs (bad for logs, TLS and DHCP lease times). The client
# was disabled before this was codified (found in the 2026-10-08 audit).
resource "routeros_system_ntp_client" "this" {
  enabled = true
  mode    = "unicast"
  servers = ["0.id.pool.ntp.org", "1.id.pool.ntp.org", "time.cloudflare.com"]
}

# --- management-plane hardening ---------------------------------------------------
# Every interface except the household side (ether1). MAC-layer access
# (MAC-Telnet, MAC-WinBox) and neighbor discovery bypass the IP firewall, so
# they must not face WAN: before this, anyone on the household Wi-Fi could
# reach the hEX login over MAC-WinBox. The OOB port (ether3) and all lab VLANs
# keep MAC access — only WAN is excluded.
resource "routeros_interface_list" "not_wan" {
  name    = "NOT-WAN"
  include = "all"
  exclude = routeros_interface_list.wan.name
  comment = "every interface except the household side"
}

resource "routeros_tool_mac_server" "this" {
  allowed_interface_list = routeros_interface_list.not_wan.name
}

resource "routeros_tool_mac_server_winbox" "this" {
  allowed_interface_list = routeros_interface_list.not_wan.name
}

resource "routeros_ip_neighbor_discovery_settings" "this" {
  discover_interface_list = routeros_interface_list.not_wan.name
}

# Bandwidth-test server: not used; off.
resource "routeros_tool_bandwidth_server" "this" {
  enabled = false
}

# Plaintext management services: off. Management uses SSH (22), REST/WebFig
# over HTTPS (www-ssl, 443 — what OpenTofu talks to) and WinBox (8291).
# The input chain already drops these from everywhere; this is defense in
# depth so a future firewall mistake does not expose them.
resource "routeros_ip_service" "plaintext_off" {
  for_each = {
    ftp    = 21
    telnet = 23
    www    = 80
    api    = 8728
  }

  numbers  = each.key
  port     = each.value
  disabled = true
}
