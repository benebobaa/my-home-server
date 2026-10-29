# Zone settings this stack owns. Everything else is still the dashboard
# default.

# Browser Integrity Check off on kubeletto.app (2026-10-29). The zone carries
# only tenant traffic (*.kubeletto.app and tenants' custom domains through
# Cloudflare for SaaS), mostly APIs called by programs. BIC answered 403
# "error code: 1010" to Python's urllib user agent before any request
# reached the tenant, so a tenant's real clients failed with an error that
# never appeared in the tenant's logs; requests, httpx, Go, Node, okhttp and
# an empty user agent passed, so the check only stopped the one client a
# header change gets past. kubeletto.com (console, platform API) keeps it.
resource "cloudflare_zone_setting" "app_browser_check" {
  zone_id    = local.zone_id.app
  setting_id = "browser_check"
  value      = "off"
}
