# Internal names under home.arpa (RFC 8375), answered by the hEX resolver.
# Public names (kubeletto.com, kubeletto.app) live on Cloudflare DNS, never here.
resource "routeros_ip_dns_record" "home_arpa" {
  for_each = {
    "hex"        = "10.10.10.1"
    "pve2"       = "10.10.10.12"
    "pve3"       = "10.10.10.13"
    "admin-gw"   = "10.10.10.15"
    "monitoring" = "10.10.10.16"
    "switch"     = "192.168.99.2"
  }

  type    = "A"
  name    = "${each.key}.home.arpa"
  address = each.value
  comment = "managed by OpenTofu"
}
