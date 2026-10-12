# Cloudflare for SaaS on kubeletto.app: tenants' custom domains (Kubeletto
# decision D4). Usage-based: 100 custom hostnames free, then $0.10 each per
# month; Kubeletto caps how many it creates.
#
# Split of ownership: this stack owns the zone-level pieces (the fallback
# origin and its record, the tunnel's catch-all in tunnel.tf). The per-domain
# custom hostnames belong to Kubeletto (its own token, SSL and Certificates
# only, on kubeletto.app), so they are never in this state.
#
# A customer CNAMEs their domain to a proxied name in this zone; Cloudflare
# issues the certificate and sends the request to the fallback origin, i.e.
# the tunnel. domains.kubeletto.app is the name customers are told to use; it
# still points DNS-only at the rented server until cutover, when it becomes a
# proxied CNAME to saas-origin (docs/runbooks/kubeletto-migration.md).

resource "cloudflare_dns_record" "saas_origin" {
  zone_id = local.zone_id.app
  name    = local.saas_origin
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}

resource "cloudflare_custom_hostname_fallback_origin" "app" {
  zone_id = local.zone_id.app
  origin  = cloudflare_dns_record.saas_origin.name
}

# A test custom domain we own, for the D4 rehearsal: CNAMEd like a customer's
# (DNS only, in another zone) and registered as a custom hostname by
# Kubeletto's internal canary tenant. Remove after cutover.
resource "cloudflare_dns_record" "saas_test" {
  zone_id = local.zone_id.com
  name    = "saas-test.kubeletto.com"
  type    = "CNAME"
  content = cloudflare_dns_record.saas_origin.name
  ttl     = 1
  proxied = false
}
