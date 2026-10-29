# cloudflare — public DNS and the tunnel

OpenTofu stack for the Cloudflare side of public ingress
([ADR 0004](../../docs/decisions/0004-public-ingress-cloudflare-tunnel.md)):
the DNS records of `kubeletto.com` and `kubeletto.app`, and the Cloudflare
Tunnel for Kubeletto's move home (`tunnel.tf`; its connector:
[`services/cloudflared/`](../../services/cloudflared/)).

```bash
cd network/cloudflare
sops exec-env secrets.sops.env 'tofu plan'
sops exec-env secrets.sops.env 'tofu apply'
```

| | |
| --- | --- |
| Records | `records.tf`: all 23, imported as they were on 2026-10-11 (`imports.tf`), generated from the API once and edited by hand since |
| Token | `CLOUDFLARE_API_TOKEN` in `secrets.sops.env`: account-owned "Agentic Claude Code" — cloudflared edit (account), DNS edit + zone read (the two zones). It can also edit zone settings (applied `settings.tf` on 2026-10-29), so the list above is incomplete: check the token's permissions in the dashboard. No registrar, no account DNS products |
| Zone settings | `settings.tf`: Browser Integrity Check **off** on `kubeletto.app` (tenant traffic: programs calling APIs; it 403'd Python's urllib before the request reached the tenant). `kubeletto.com` keeps the default (on). Other settings are dashboard defaults, not managed here |
| Custom domains | `saas.tf`: Cloudflare for SaaS on `kubeletto.app` (Kubeletto decision D4; 100 hostnames free, then $0.10/month each). This stack owns the fallback origin `saas-origin.kubeletto.app` (proxied CNAME → the tunnel) and the tunnel's catch-all; the per-domain custom hostnames belong to Kubeletto, created with its own token (`CLOUDFLARE_SAAS_TOKEN` in `services/kubeletto/secrets.sops.env`: SSL and Certificates edit, `kubeletto.app` only). `saas-test.kubeletto.com` is our own test domain |
| Tunnel | `tunnel.tf`: `kubeletto-home`, remote-managed ingress rules, the connector deployed into K3s through root SSH to pve2 + the guest agent (so this stack needs the lab and the admin key, like `proxmox/opentofu`) |
| State | encrypted (`encryption.tf`, its own `TF_VAR_state_passphrase`), committed |

A record changed in the dashboard is **drift**: change `records.tf` and
apply instead. Internal names are not here: they live on the hEX under
`home.arpa` (no split horizon, ADR 0004).

## Records that matter for the move

| Record | Today | At cutover |
| --- | --- | --- |
| `*.kubeletto.app`, `api.kubeletto.com` | A → the rented server, proxied | CNAME → the tunnel |
| `domains.kubeletto.app` (+ `cd-spike` CNAME to it) | A → the rented server, **DNS-only**: customers' domains CNAME here and the server gets their certificates itself | proxied CNAME → `saas-origin.kubeletto.app`; Kubeletto registers each domain as a custom hostname and Cloudflare issues its certificate (`saas.tf`) |
| `traefik-staging.kubeletto.com` | A → a Tailscale address, DNS-only | remove with the old server |

Everything else (Pages sites, Vercel `www`, Hostinger mail + DKIM, Resend,
PostHog, Better Stack, R2 releases) does not depend on where Kubeletto runs.
