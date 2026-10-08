# Default-deny firewall, NAT and the PPPoE MSS clamp.
# Rule order matters! RouterOS appends new rules to the END of a chain, so any
# rule that must sit mid-chain sets `place_before = <the rule that follows it>`
# (see forward_switch_mgmt). The rest are chained with depends_on so a full
# rebuild creates them in the intended order.

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
  comment = "Tailscale admin gateway (CT 101 on pve3)"
}

resource "routeros_ip_firewall_addr_list" "biznet_lan" {
  list    = "biznet-lan"
  address = "192.168.18.0/24"
  comment = "Biznet household LAN - never reachable from the lab"
}

# Non-public destinations the DMZ must never reach through the WAN. Biznet's
# own CGNAT network is 10.x: a tenant scanning it would be seen by the ISP, on
# the household's account.
resource "routeros_ip_firewall_addr_list" "non_public" {
  for_each = {
    "10.0.0.0/8"     = "RFC1918 (incl. Biznet CGNAT internals)"
    "172.16.0.0/12"  = "RFC1918"
    "192.168.0.0/16" = "RFC1918 (incl. the Biznet household LAN)"
    "100.64.0.0/10"  = "CGNAT shared space"
    "169.254.0.0/16" = "link-local"
  }

  list    = "non-public"
  address = each.key
  comment = each.value
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
# The DMZ (VLAN 25) is never fasttracked: fasttracked packets skip the simple
# queue that caps its internet bandwidth (queues.tf). Replies to DMZ flows are
# already de-NATed in forward, so dst covers both directions.
resource "routeros_ip_firewall_filter" "forward_fasttrack" {
  chain            = "forward"
  action           = "fasttrack-connection"
  connection_state = "established,related"
  src_address      = "!10.10.25.0/24"
  dst_address      = "!10.10.25.0/24"
  comment          = "offload established flows (not the DMZ)"
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

# DMZ = tenant zone (it will run other people's code). Its internet egress
# leaves from the household's IP, so the abuse that gets an IP reported is cut
# here. Logged: a hit is the earliest abuse signal.
resource "routeros_ip_firewall_filter" "forward_dmz_no_smtp" {
  chain              = "forward"
  action             = "drop"
  src_address        = "10.10.25.0/24"
  out_interface_list = routeros_interface_list.wan.name
  protocol           = "tcp"
  dst_port           = "25"
  log                = true
  log_prefix         = "dmz-smtp"
  comment            = "DMZ: no outbound SMTP (spam from the household IP)"
  place_before       = routeros_ip_firewall_filter.forward_dmz_no_private.id
}

resource "routeros_ip_firewall_filter" "forward_dmz_no_private" {
  chain              = "forward"
  action             = "drop"
  src_address        = "10.10.25.0/24"
  out_interface_list = routeros_interface_list.wan.name
  dst_address_list   = "non-public"
  depends_on         = [routeros_ip_firewall_addr_list.non_public]
  log                = true
  log_prefix         = "dmz-private"
  comment            = "DMZ: no private/CGNAT destinations via WAN (ISP internals)"
  place_before       = routeros_ip_firewall_filter.forward_trusted_internal.id
}

resource "routeros_ip_firewall_filter" "forward_trusted_internal" {
  chain       = "forward"
  action      = "accept"
  src_address = "10.10.40.0/24"
  dst_address = "10.10.0.0/16"
  comment     = "TRUSTED to internal"
  depends_on  = [routeros_ip_firewall_filter.forward_invalid]
}

# DMZ -> backend pinholes: one rule per exact source/destination/port. Nothing
# else in the DMZ reaches another VLAN.
# K3s VM (Kubeletto) -> its Postgres. Both hosts are reserved in design §2 and
# not built yet.
resource "routeros_ip_firewall_filter" "forward_k3s_postgres" {
  chain        = "forward"
  action       = "accept"
  src_address  = "10.10.25.20"
  dst_address  = "10.10.20.21"
  protocol     = "tcp"
  dst_port     = "5432"
  comment      = "DMZ pinhole: K3s VM to Postgres"
  place_before = routeros_ip_firewall_filter.forward_admin_gw.id
}

resource "routeros_ip_firewall_filter" "forward_admin_gw" {
  chain            = "forward"
  action           = "accept"
  src_address_list = "admin-gw"
  dst_address      = "10.10.0.0/16"
  comment          = "admin-gw to internal"
  depends_on       = [routeros_ip_firewall_filter.forward_trusted_internal]
}

resource "routeros_ip_firewall_filter" "forward_switch_mgmt" {
  chain            = "forward"
  action           = "accept"
  src_address_list = "admin-src"
  dst_address      = "192.168.99.2"
  protocol         = "tcp"
  dst_port         = "80,443"
  comment          = "admin to the switch management UI"
  place_before     = routeros_ip_firewall_filter.forward_no_biznet.id
  depends_on       = [routeros_ip_firewall_filter.forward_admin_gw]
}

resource "routeros_ip_firewall_filter" "forward_no_biznet" {
  chain              = "forward"
  action             = "drop"
  dst_address_list   = "biznet-lan"
  out_interface_list = routeros_interface_list.wan.name
  comment            = "lab must not reach Biznet/household LAN"
  depends_on         = [routeros_ip_firewall_filter.forward_admin_gw]
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
