# Physical ports, VLANs on the trunk to the switch (ether5), and interface lists.

# --- physical ----------------------------------------------------------------
# WAN port. MTU 1492 because the upstream path is PPPoE (MRU 1492); the MSS
# clamp in firewall.tf then computes 1452 automatically.
# Existing interface: import once before the first apply ->
#   tofu import routeros_interface_ethernet.wan ether1
resource "routeros_interface_ethernet" "wan" {
  factory_name = "ether1"
  name         = "ether1"
  mtu          = 1492
}

# --- VLANs on the trunk to the switch (ether5) --------------------------------
resource "routeros_interface_vlan" "mgmt" {
  name      = "vlan10-mgmt"
  interface = "ether5"
  vlan_id   = 10
  comment   = "MGMT"
}

resource "routeros_interface_vlan" "servers" {
  name      = "vlan20-servers"
  interface = "ether5"
  vlan_id   = 20
  comment   = "SERVERS"
}

resource "routeros_interface_vlan" "dmz" {
  name      = "vlan25-dmz"
  interface = "ether5"
  vlan_id   = 25
  comment   = "DMZ"
}

resource "routeros_interface_vlan" "lab" {
  name      = "vlan30-lab"
  interface = "ether5"
  vlan_id   = 30
  comment   = "LAB"
}

resource "routeros_interface_vlan" "trusted" {
  name      = "vlan40-trusted"
  interface = "ether5"
  vlan_id   = 40
  comment   = "TRUSTED"
}

resource "routeros_interface_vlan" "iot" {
  name      = "vlan50-iot"
  interface = "ether5"
  vlan_id   = 50
  comment   = "IOT/GUEST"
}

# --- interface lists -----------------------------------------------------------
resource "routeros_interface_list" "wan" {
  name    = "WAN"
  comment = "the outside"
}

resource "routeros_interface_list" "lan" {
  name    = "LAN"
  comment = "the lab side"
}

resource "routeros_interface_list_member" "wan_ether1" {
  list      = routeros_interface_list.wan.name
  interface = "ether1"
}

resource "routeros_interface_list_member" "lan_mgmt" {
  list      = routeros_interface_list.lan.name
  interface = routeros_interface_vlan.mgmt.name
}

resource "routeros_interface_list_member" "lan_servers" {
  list      = routeros_interface_list.lan.name
  interface = routeros_interface_vlan.servers.name
}

resource "routeros_interface_list_member" "lan_dmz" {
  list      = routeros_interface_list.lan.name
  interface = routeros_interface_vlan.dmz.name
}

resource "routeros_interface_list_member" "lan_lab" {
  list      = routeros_interface_list.lan.name
  interface = routeros_interface_vlan.lab.name
}

resource "routeros_interface_list_member" "lan_trusted" {
  list      = routeros_interface_list.lan.name
  interface = routeros_interface_vlan.trusted.name
}

resource "routeros_interface_list_member" "lan_iot" {
  list      = routeros_interface_list.lan.name
  interface = routeros_interface_vlan.iot.name
}
