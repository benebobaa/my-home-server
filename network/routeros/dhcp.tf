# DHCP for the client VLANs (LAB, TRUSTED, IOT). MGMT/SERVERS/DMZ use static IPs.

# --- LAB -----------------------------------------------------------------------
resource "routeros_ip_pool" "lab" {
  name   = "pool30-lab"
  ranges = [local.dhcp_range.lab]
}

resource "routeros_ip_dhcp_server" "lab" {
  name                      = "dhcp30-lab"
  interface                 = routeros_interface_vlan.lab.name
  address_pool              = routeros_ip_pool.lab.name
  lease_time                = "12h"
  dynamic_lease_identifiers = "client-mac,client-id" # pinned: RouterOS default
}

resource "routeros_ip_dhcp_server_network" "lab" {
  address    = local.vlan.lab.cidr
  gateway    = local.vlan.lab.gateway
  dns_server = [local.vlan.lab.gateway]
}

# --- TRUSTED -------------------------------------------------------------------
resource "routeros_ip_pool" "trusted" {
  name   = "pool40-trusted"
  ranges = [local.dhcp_range.trusted]
}

resource "routeros_ip_dhcp_server" "trusted" {
  name                      = "dhcp40-trusted"
  interface                 = routeros_interface_vlan.trusted.name
  address_pool              = routeros_ip_pool.trusted.name
  lease_time                = "12h"
  dynamic_lease_identifiers = "client-mac,client-id" # pinned: RouterOS default
}

resource "routeros_ip_dhcp_server_network" "trusted" {
  address    = local.vlan.trusted.cidr
  gateway    = local.vlan.trusted.gateway
  dns_server = [local.vlan.trusted.gateway]
}

# --- IOT/GUEST -------------------------------------------------------------------
resource "routeros_ip_pool" "iot" {
  name   = "pool50-iot"
  ranges = [local.dhcp_range.iot]
}

resource "routeros_ip_dhcp_server" "iot" {
  name                      = "dhcp50-iot"
  interface                 = routeros_interface_vlan.iot.name
  address_pool              = routeros_ip_pool.iot.name
  lease_time                = "12h"
  dynamic_lease_identifiers = "client-mac,client-id" # pinned: RouterOS default
}

resource "routeros_ip_dhcp_server_network" "iot" {
  address    = local.vlan.iot.cidr
  gateway    = local.vlan.iot.gateway
  dns_server = [local.vlan.iot.gateway]
}
