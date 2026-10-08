# 0004 — Public ingress through Cloudflare Tunnel; VPS path deferred

**Status:** accepted (2026-10-08). Supersedes the "public exposure through a
rented VPS (no Cloudflare Tunnel)" choice in `docs/design/network-design.md`
§6 (v2 draft, never built).

## Context

The lab sits behind Biznet CGNAT plus a double NAT, so inbound connections
are impossible; anything public must ride an outbound tunnel. The v2 design
planned a VPS (HAProxy L4 + WireGuard → an edge LXC terminating TLS at home).
That design's main reason to avoid Cloudflare Tunnel was that **no third
party should decrypt the traffic**.

The first real public workload is **Kubeletto** (`kubeletto.com`,
`kubeletto.app`, `*.kubeletto.app`), moving home to cut ~525k IDR/month of
cloud cost. Both zones already use Cloudflare nameservers, and every hostname
is already **proxied by Cloudflare** (orange cloud): Cloudflare already
terminates TLS for it. Kubeletto's Traefik already reads `CF-Connecting-IP`
for rate limits and logs.

Options considered:

- **Cloudflare Tunnel** (`cloudflared`, outbound-only): free; no public IP or
  VPS to harden; keeps Cloudflare's DDoS protection, WAF, cache and Access;
  supports wildcard hostnames. Limits on the free plan: HTTP(S)/WebSocket
  only, 100 MB request bodies, CDN terms restrict media serving.
- **VPS + WireGuard (v2 design):** end-to-end TLS, raw TCP/UDP, but a box to
  pay for, patch and harden, and no gain for zones already proxied.
- **MikroTik CHR on the VPS:** cannot send PROXY protocol (client IP lost on
  L4 passthrough); paid license above 1 Mbps.
- **WireGuard terminating on the hEX:** puts an untrusted peer on the core
  router that holds the management path.

## Decision

- **Public HTTP(S) ingress = Cloudflare Tunnel.** `cloudflared` runs inside
  the tenant cluster (two replicas) in the DMZ (VLAN 25), dialing out. Still
  zero inbound ports at home.
- **Cloudflare DNS stays authoritative** for the public zones, managed as code
  in a dedicated OpenTofu stack (existing records are imported first: Hostinger
  MX, SPF/SES, verification TXT, Vercel `www`, `posthog`). Internal names stay
  on the hEX under `home.arpa`; no split-horizon (HSTS `includeSubDomains;
  preload` on `kubeletto.com` makes every subdomain HTTPS-only, and LAN clients
  simply go through Cloudflare).
- **Admin never goes public.** Proxmox, the hEX, the switch and cluster
  APIs stay Tailscale-only (`admin-gw`); any admin web UI that must be on a
  public hostname sits behind Cloudflare Access.
- **The VPS path is deferred**, not rejected. Build it only when one of
  these triggers appears: non-HTTP ports must be public; media streaming or
  >100 MB uploads; or tenant egress from the household IP draws abuse
  reports (then the VPS becomes the DMZ's egress exit). The v2 design in
  §6 is kept as that fallback's blueprint.

## Consequences

- Cloudflare sees plaintext for the tunnelled hostnames — already true today
  for Kubeletto.
- No VPS cost; one less internet-facing host to patch.
- The DMZ is the tenant zone and is filtered accordingly (as built
  2026-10-08: no SMTP-25, no non-public egress via WAN, 50/50 Mbps cap,
  exact pinholes; design §4).
- Tenant workloads run in a **VM**, not an LXC: tenants execute arbitrary
  code, and a container escape from an LXC is root on the Proxmox host.
- Public availability is bounded by the home line and power (no SLA, no UPS
  yet) — accepted for a project with no paid users.
- New secrets in SOPS: a Cloudflare API token (scoped to the two zones: DNS
  edit + Tunnel edit) and the tunnel credentials.
