# Cloudflare (ADR 0004): DNS for the public zones, and later the tunnel.
# The API token is CLOUDFLARE_API_TOKEN in secrets.sops.env (account-owned
# token "Agentic Claude Code": cloudflared edit on the account; DNS edit +
# zone read on kubeletto.com and kubeletto.app). Run tofu as:
#   sops exec-env secrets.sops.env 'tofu plan'
provider "cloudflare" {}
