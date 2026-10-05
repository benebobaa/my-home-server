# Default-deny firewall, NAT and the PPPoE MSS clamp.
# Rule order matters: rules are chained with depends_on so they are created in
# sequence. This also keeps the OOB management connection (ether3) alive while
# the chain is being built.

# --- address lists --------------------------------------------------------------
resource "routeros_ip_firewall_addr_list" "admin_src_trusted" {
  list    = "admin-src"
  address = "10.10.40.0/24"
  comment = "TRUSTED"
}

resource "routeros_ip_firewall_addr_list" "admin_src_mgmt" {
  list    = "admin-src"
  address = "10.10.10.0/24"
  comment = "MGMT"
}

resource "routeros_ip_firewall_addr_list" "admin_src_native" {
  list    = "admin-src"
  address = "192.168.99.0/29"
  comment = "switch management / P1 recovery segment"
}

resource "routeros_ip_firewall_addr_list" "admin_gw" {
  list    = "admin-gw"
  address = "10.10.10.15"
  comment = "Tailscale admin gateway (planned)"
}

resource "routeros_ip_firewall_addr_list" "biznet_lan" {
  list    = "biznet-lan"
  address = "192.168.18.0/24"
  comment = "Biznet household LAN - never reachable from the lab"
}

# --- input ----------------------------------------------------------------------
resource "routeros_ip_firewall_filter" "input_established" {
  chain            = "input"
  action           = "accept"
  connection_state = "established,related"
  comment          = "replies to conversations we started"
}

resource "routeros_ip_firewall_filter" "input_invalid" {
  chain            = "input"
  action           = "drop"
  connection_state = "invalid"
  comment          = "nonsense in, gone"
  depends_on       = [routeros_ip_firewall_filter.input_established]
}

resource "routeros_ip_firewall_filter" "input_icmp" {
  chain      = "input"
  action     = "accept"
  protocol   = "icmp"
  comment    = "let the world ping me"
  depends_on = [routeros_ip_firewall_filter.input_invalid]
}

resource "routeros_ip_firewall_filter" "input_dns_dhcp_udp" {
  chain             = "input"
  action            = "accept"
  in_interface_list = routeros_interface_list.lan.name
  protocol          = "udp"
  dst_port          = "53,67"
  comment           = "DNS + DHCP for the lab"
  depends_on        = [routeros_ip_firewall_filter.input_icmp]
}

resource "routeros_ip_firewall_filter" "input_dns_tcp" {
  chain             = "input"
  action            = "accept"
  in_interface_list = routeros_interface_list.lan.name
  protocol          = "tcp"
  dst_port          = "53"
  comment           = "DNS over TCP"
  depends_on        = [routeros_ip_firewall_filter.input_dns_dhcp_udp]
}

resource "routeros_ip_firewall_filter" "input_admin" {
  chain            = "input"
  action           = "accept"
  src_address_list = "admin-src"
  protocol         = "tcp"
  dst_port         = "22,443,8291"
  comment          = "admin: SSH, REST/WebFig, Winbox"
  depends_on       = [routeros_ip_firewall_filter.input_dns_tcp]
}

resource "routeros_ip_firewall_filter" "input_oob" {
  chain        = "input"
  action       = "accept"
  in_interface = "ether3"
  comment      = "OOB recovery port"
  depends_on   = [routeros_ip_firewall_filter.input_admin]
}

resource "routeros_ip_firewall_filter" "input_drop" {
  chain      = "input"
  action     = "drop"
  comment    = "drop everything else"
  depends_on = [routeros_ip_firewall_filter.input_oob]
}

# --- forward --------------------------------------------------------------------
resource "routeros_ip_firewall_filter" "forward_fasttrack" {
  chain            = "forward"
  action           = "fasttrack-connection"
  connection_state = "established,related"
  comment          = "offload established flows"
  depends_on       = [routeros_ip_firewall_filter.input_drop]
}

resource "routeros_ip_firewall_filter" "forward_established" {
  chain            = "forward"
  action           = "accept"
  connection_state = "established,related"
  comment          = "replies to conversations we started"
  depends_on       = [routeros_ip_firewall_filter.forward_fasttrack]
}

resource "routeros_ip_firewall_filter" "forward_invalid" {
  chain            = "forward"
  action           = "drop"
  connection_state = "invalid"
  depends_on       = [routeros_ip_firewall_filter.forward_established]
}

resource "routeros_ip_firewall_filter" "forward_trusted_internal" {
  chain       = "forward"
  action      = "accept"
  src_address = "10.10.40.0/24"
  dst_address = "10.10.0.0/16"
  comment     = "TRUSTED to internal"
  depends_on  = [routeros_ip_firewall_filter.forward_invalid]
}

resource "routeros_ip_firewall_filter" "forward_dmz_backends" {
  chain            = "forward"
  action           = "accept"
  src_address      = "10.10.25.0/24"
  dst_address_list = "dmz-backends"
  protocol         = "tcp"
  dst_port         = "443,8080"
  comment          = "DMZ to allowlisted backends only"
  depends_on       = [routeros_ip_firewall_filter.forward_trusted_internal]
}

resource "routeros_ip_firewall_filter" "forward_admin_gw" {
  chain            = "forward"
  action           = "accept"
  src_address_list = "admin-gw"
  dst_address      = "10.10.0.0/16"
  comment          = "admin-gw to internal"
  depends_on       = [routeros_ip_firewall_filter.forward_dmz_backends]
}

resource "routeros_ip_firewall_filter" "forward_switch_mgmt" {
  chain            = "forward"
  action           = "accept"
  src_address_list = "admin-src"
  dst_address      = "192.168.99.2"
  protocol         = "tcp"
  dst_port         = "80,443"
  comment          = "admin to the switch management UI"
  depends_on       = [routeros_ip_firewall_filter.forward_admin_gw]
}

resource "routeros_ip_firewall_filter" "forward_no_biznet" {
  chain              = "forward"
  action             = "drop"
  dst_address_list   = "biznet-lan"
  out_interface_list = routeros_interface_list.wan.name
  comment            = "lab must not reach Biznet/household LAN"
  depends_on         = [routeros_ip_firewall_filter.forward_switch_mgmt]
}

resource "routeros_ip_firewall_filter" "forward_drop_inter_vlan" {
  chain              = "forward"
  action             = "drop"
  in_interface_list  = routeros_interface_list.lan.name
  out_interface_list = routeros_interface_list.lan.name
  comment            = "default deny between lab VLANs"
  depends_on         = [routeros_ip_firewall_filter.forward_no_biznet]
}

resource "routeros_ip_firewall_filter" "forward_lan_wan" {
  chain              = "forward"
  action             = "accept"
  in_interface_list  = routeros_interface_list.lan.name
  out_interface_list = routeros_interface_list.wan.name
  comment            = "internet for the lab"
  depends_on         = [routeros_ip_firewall_filter.forward_drop_inter_vlan]
}

resource "routeros_ip_firewall_filter" "forward_drop" {
  chain      = "forward"
  action     = "drop"
  comment    = "default drop"
  depends_on = [routeros_ip_firewall_filter.forward_lan_wan]
}

# --- NAT + MSS clamp -------------------------------------------------------------
resource "routeros_ip_firewall_nat" "masquerade" {
  chain              = "srcnat"
  action             = "masquerade"
  out_interface_list = routeros_interface_list.wan.name
  comment            = "share the Biznet address"
}

resource "routeros_ip_firewall_mangle" "mss_clamp" {
  chain              = "forward"
  action             = "change-mss"
  new_mss            = "clamp-to-pmtu"
  passthrough        = true
  protocol           = "tcp"
  tcp_flags          = "syn"
  out_interface_list = routeros_interface_list.wan.name
  comment            = "PPPoE upstream (1492): clamp TCP MSS"
}
