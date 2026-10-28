# DNS records of the public zones, imported as they were on 2026-10-11 (ADR 0004).
# Generated once from the Cloudflare API, then edited by hand: this file is
# the source of truth from now on. A record changed in the dashboard is drift.

# CUTOVER (docs/runbooks/kubeletto-cutover.md step 9): was an A record to the
# rented server (103.59.160.198, proxied). Rollback: put that A record back.
resource "cloudflare_dns_record" "app_wildcard_a" {
  zone_id = local.zone_id.app
  name    = "*.kubeletto.app"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}

# CUTOVER: was a DNS-only A record to the rented server. Customers' custom
# domains CNAME to this name; proxied and pointing at the zone's fallback
# origin it becomes Cloudflare for SaaS (the custom hostnames validate and go
# ACTIVE on their own). Rollback: DNS-only A 103.59.160.198.
resource "cloudflare_dns_record" "app_domains_a" {
  zone_id = local.zone_id.app
  name    = "domains.kubeletto.app"
  type    = "CNAME"
  content = local.saas_origin
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "com_dmarc_txt" {
  zone_id = local.zone_id.com
  name    = "_dmarc.kubeletto.com"
  type    = "TXT"
  content = "\"v=DMARC1; p=none\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_ai_cname" {
  zone_id = local.zone_id.com
  name    = "ai.kubeletto.com"
  type    = "CNAME"
  content = "web.tpcdns.com"
  ttl     = 1
  proxied = false
}

# CUTOVER: was a proxied A record to the rented server. Rollback: put it back.
resource "cloudflare_dns_record" "com_api_a" {
  zone_id = local.zone_id.com
  name    = "api.kubeletto.com"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}

# The admin plane (ADR 0026). Off until a Cloudflare Access application covers
# admin-api.kubeletto.com: an open hostname would be the admin login exposed to
# the internet. Set admin_api_public = true only after the operator confirms
# Access is enforcing for it, and then apply.
variable "admin_api_public" {
  description = "Publish admin-api.kubeletto.com. Keep false until a Cloudflare Access policy covers it (ADR 0026)."
  type        = bool
  default     = false
}

resource "cloudflare_dns_record" "com_admin_api_cname" {
  count   = var.admin_api_public ? 1 : 0
  zone_id = local.zone_id.com
  name    = "admin-api.kubeletto.com"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "com_cd_spike_cname" {
  zone_id = local.zone_id.com
  name    = "cd-spike.kubeletto.com"
  type    = "CNAME"
  content = "domains.kubeletto.app"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_console_cname" {
  zone_id = local.zone_id.com
  name    = "console.kubeletto.com"
  type    = "CNAME"
  content = "kubeletto-console.pages.dev"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "com_hostingermail_a_domainkey_cname" {
  zone_id = local.zone_id.com
  name    = "hostingermail-a._domainkey.kubeletto.com"
  type    = "CNAME"
  content = "hostingermail-a.dkim.mail.hostinger.com"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_hostingermail_b_domainkey_cname" {
  zone_id = local.zone_id.com
  name    = "hostingermail-b._domainkey.kubeletto.com"
  type    = "CNAME"
  content = "hostingermail-b.dkim.mail.hostinger.com"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_hostingermail_c_domainkey_cname" {
  zone_id = local.zone_id.com
  name    = "hostingermail-c._domainkey.kubeletto.com"
  type    = "CNAME"
  content = "hostingermail-c.dkim.mail.hostinger.com"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_apex_cname" {
  zone_id = local.zone_id.com
  name    = "kubeletto.com"
  type    = "CNAME"
  content = "kubeletto-site.pages.dev"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "com_apex_mx" {
  zone_id  = local.zone_id.com
  name     = "kubeletto.com"
  type     = "MX"
  content  = "mx1.hostinger.com"
  ttl      = 1
  proxied  = false
  priority = 5
}

resource "cloudflare_dns_record" "com_apex_mx_2" {
  zone_id  = local.zone_id.com
  name     = "kubeletto.com"
  type     = "MX"
  content  = "mx2.hostinger.com"
  ttl      = 1
  proxied  = false
  priority = 10
}

resource "cloudflare_dns_record" "com_apex_txt" {
  zone_id = local.zone_id.com
  name    = "kubeletto.com"
  type    = "TXT"
  content = "\"4cc22908bd8c58ad5ed29056f36fb5ae\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_apex_txt_2" {
  zone_id = local.zone_id.com
  name    = "kubeletto.com"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.mail.hostinger.com include:amazonses.com ~all\""
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_posthog_cname" {
  zone_id = local.zone_id.com
  name    = "posthog.kubeletto.com"
  type    = "CNAME"
  content = "7516e2dac8ab2269e21a.cf-prod-us-proxy.proxyhog.com"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_releases_cname" {
  zone_id = local.zone_id.com
  name    = "releases.kubeletto.com"
  type    = "CNAME"
  content = "public.r2.dev"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "com_resend_domainkey_txt" {
  zone_id = local.zone_id.com
  name    = "resend._domainkey.kubeletto.com"
  type    = "TXT"
  content = "\"p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDUPiWHQ2UHZ9IT9WWDTgPiS8CwlGNdkQ8wgZf13JaR3uYqcN7Qhy8iy2d+pGEf6C4MWsJxMDikxQzBEX9Oixue0BWcnP1wa+McHUDqna9j2O4mSgO0T0gUubxz/DU9nba7rWScDewjQHuiGN0lgghLo3LcXS4htGI4d1Nsu2O0TwIDAQAB\""
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "com_send_mx" {
  zone_id  = local.zone_id.com
  name     = "send.kubeletto.com"
  type     = "MX"
  content  = "feedback-smtp.ap-northeast-1.amazonses.com"
  ttl      = 3600
  proxied  = false
  priority = 10
}

resource "cloudflare_dns_record" "com_send_txt" {
  zone_id = local.zone_id.com
  name    = "send.kubeletto.com"
  type    = "TXT"
  content = "\"v=spf1 include:amazonses.com ~all\""
  ttl     = 3600
  proxied = false
}

resource "cloudflare_dns_record" "com_status_cname" {
  zone_id = local.zone_id.com
  name    = "status.kubeletto.com"
  type    = "CNAME"
  content = "statuspage.betteruptime.com"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "com_traefik_staging_a" {
  zone_id = local.zone_id.com
  name    = "traefik-staging.kubeletto.com"
  type    = "A"
  content = "100.103.152.101"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "com_www_cname" {
  zone_id = local.zone_id.com
  name    = "www.kubeletto.com"
  type    = "CNAME"
  content = "e8e3311729e6a5fb.vercel-dns-017.com"
  ttl     = 1
  proxied = false
}

