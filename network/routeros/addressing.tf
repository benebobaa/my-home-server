# Static addresses + the WAN DHCP client.

# Native VLAN (untagged) on the trunk: switch management segment.
resource "routeros_ip_address" "switch_mgmt" {
  address   = "192.168.99.1/29"
  interface = "ether5"
  comment   = "switch management (native VLAN)"
}

resource "routeros_ip_address" "mgmt" {
  address   = "10.10.10.1/24"
  interface = routeros_interface_vlan.mgmt.name
  comment   = "MGMT gateway"
}

resource "routeros_ip_address" "servers" {
  address   = "10.10.20.1/24"
  interface = routeros_interface_vlan.servers.name
  comment   = "SERVERS gateway"
}

resource "routeros_ip_address" "dmz" {
  address   = "10.10.25.1/24"
  interface = routeros_interface_vlan.dmz.name
  comment   = "DMZ gateway"
}

resource "routeros_ip_address" "lab" {
  address   = "10.10.30.1/24"
  interface = routeros_interface_vlan.lab.name
  comment   = "LAB gateway"
}

resource "routeros_ip_address" "trusted" {
  address   = "10.10.40.1/24"
  interface = routeros_interface_vlan.trusted.name
  comment   = "TRUSTED gateway"
}

resource "routeros_ip_address" "iot" {
  address   = "10.10.50.1/24"
  interface = routeros_interface_vlan.iot.name
  comment   = "IOT gateway"
}

# WAN: pick up an address + default route from the Biznet router.
resource "routeros_ip_dhcp_client" "wan" {
  interface         = "ether1"
  add_default_route = "yes"
  use_peer_dns      = false
  comment           = "uplink to the Biznet router"
}
