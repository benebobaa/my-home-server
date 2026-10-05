# DHCP for the client VLANs (LAB, TRUSTED, IOT). MGMT/SERVERS/DMZ use static IPs.

# --- LAB -----------------------------------------------------------------------
resource "routeros_ip_pool" "lab" {
  name   = "pool30-lab"
  ranges = ["10.10.30.100-10.10.30.199"]
}

resource "routeros_ip_dhcp_server" "lab" {
  name                      = "dhcp30-lab"
  interface                 = routeros_interface_vlan.lab.name
  address_pool              = routeros_ip_pool.lab.name
  lease_time                = "12h"
  dynamic_lease_identifiers = "client-mac,client-id" # pinned: RouterOS default
}

resource "routeros_ip_dhcp_server_network" "lab" {
  address    = "10.10.30.0/24"
  gateway    = "10.10.30.1"
  dns_server = ["10.10.30.1"]
}

# --- TRUSTED -------------------------------------------------------------------
resource "routeros_ip_pool" "trusted" {
  name   = "pool40-trusted"
  ranges = ["10.10.40.100-10.10.40.199"]
}

resource "routeros_ip_dhcp_server" "trusted" {
  name                      = "dhcp40-trusted"
  interface                 = routeros_interface_vlan.trusted.name
  address_pool              = routeros_ip_pool.trusted.name
  lease_time                = "12h"
  dynamic_lease_identifiers = "client-mac,client-id" # pinned: RouterOS default
}

resource "routeros_ip_dhcp_server_network" "trusted" {
  address    = "10.10.40.0/24"
  gateway    = "10.10.40.1"
  dns_server = ["10.10.40.1"]
}

# --- IOT/GUEST -------------------------------------------------------------------
resource "routeros_ip_pool" "iot" {
  name   = "pool50-iot"
  ranges = ["10.10.50.100-10.10.50.199"]
}

resource "routeros_ip_dhcp_server" "iot" {
  name                      = "dhcp50-iot"
  interface                 = routeros_interface_vlan.iot.name
  address_pool              = routeros_ip_pool.iot.name
  lease_time                = "12h"
  dynamic_lease_identifiers = "client-mac,client-id" # pinned: RouterOS default
}

resource "routeros_ip_dhcp_server_network" "iot" {
  address    = "10.10.50.0/24"
  gateway    = "10.10.50.1"
  dns_server = ["10.10.50.1"]
}
