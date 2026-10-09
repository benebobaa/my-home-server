# Bandwidth cap for the DMZ (VLAN 25), the tenant zone. The line is ~90/90
# Mbps (measured 2026-10-08); the household shares it via the Biznet router,
# and corosync shares the nodes' single NIC. Capping the DMZ at ~55% keeps
# tenant builds and image pulls from starving either. `dst = ether1` scopes it
# to internet traffic, so DMZ -> backend pinholes are not throttled.
# Requires the DMZ to be excluded from fasttrack (firewall.tf).
resource "routeros_queue_simple" "dmz_internet" {
  name      = "dmz-internet"
  target    = [local.vlan.dmz.cidr]
  dst       = "ether1"
  max_limit = "50M/50M"
  comment   = "DMZ <-> internet cap (upload/download)"
}
