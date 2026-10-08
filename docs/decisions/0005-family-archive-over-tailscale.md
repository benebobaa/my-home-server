# 0005 — Family archive served over Tailscale node sharing, not Cloudflare Tunnel

**Status:** accepted (2026-10-09)

## Context

The family files rescued from two old laptop HDDs (Bene's coursework and
projects, his sister Irene's music courses and class recordings, other family
documents and photos, ~200 GB plus 120 h of video) need to be browsable and
downloadable by **two people** from phones and laptops anywhere. The files
are private, and some are large (multi-GB videos).

[ADR 0004](0004-public-ingress-cloudflare-tunnel.md) made Cloudflare Tunnel
the lab's public HTTP ingress. Options considered for this service:

- **Cloudflare Tunnel + Cloudflare Access** (email one-time PIN): no app for
  Irene to install. But Cloudflare decrypts the traffic, and the free plan's
  CDN terms restrict serving media and large files. ADR 0004 lists media as
  a trigger for the deferred VPS path, not something to push through the tunnel.
- **Tailscale node sharing:** the service container joins the existing
  tailnet as its own machine and is *shared* with Irene's Tailscale account.
  End-to-end encrypted, no media or size limits, free, and nothing public. Irene
  installs the Tailscale app once and sees only this one machine, not the lab
  or the subnet routes.
- **Expose via the admin-gw subnet routes:** that would give Irene a path into
  the lab VLANs. Rejected: admin-gw is management access only.

## Decision

- File Browser (pinned release, checksum-verified) in an unprivileged LXC on
  pve2, VLAN 20, with its own Tailscale node (`archive`), served by
  `tailscale serve` on HTTPS 443. It listens only on `127.0.0.1`.
- Read-only twice over: bind mounts are `ro=1`, and both File Browser users have
  download/preview permission only.
- Shared with Irene through Tailscale's machine sharing; each person has their
  own File Browser login.

## Consequences

- Irene needs the Tailscale app and an account on each device she uses.
- No router or Cloudflare changes. VLAN 20 needs outbound internet (it has it)
  for Tailscale.
- Interim storage is the verified second copy on pve2's SSD, not boot-safe
  until the archive moves to ZFS on the HDD (`services/archive/README.md`).
- Moving to a public URL later would need a new ADR (and the VPS path, given
  the media terms).
