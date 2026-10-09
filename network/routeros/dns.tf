# Internal names under home.arpa (RFC 8375), answered by the hEX resolver.
# Public names (kubeletto.com, kubeletto.app) live on Cloudflare DNS, never here.
resource "routeros_ip_dns_record" "home_arpa" {
  for_each = module.lab.dns_records # hosts with dns = true in lab.yaml

  type    = "A"
  name    = "${each.key}.home.arpa"
  address = each.value
  comment = "managed by OpenTofu"
}
