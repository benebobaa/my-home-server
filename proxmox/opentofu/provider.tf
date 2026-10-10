# Proxmox VE provider (bpg/proxmox).
#
# Credentials: the API token is read from the PROXMOX_VE_API_TOKEN environment
# variable, which comes from secrets.sops.env (encrypted). See README.md.
#
#   sops exec-env secrets.sops.env 'tofu plan'
#
provider "proxmox" {
  endpoint = var.proxmox_endpoint

  # Self-signed certificate on the lab nodes (management VLAN only).
  insecure = true
}

# The same API, straight to pve2. URL downloads to a node (`query-url-metadata`)
# time out with HTTP 596 when pve3 proxies them to pve2 (30 s; 2 s direct —
# found 2026-10-11), so resources that download onto pve2 use this. Address
# from inventory/lab.yaml.
#
# Open (2026-10-11): ordinary proxied reads (pve3 → pve2) also returned 596
# intermittently during plans — 2 of ~8 runs, not reproducible on demand
# (30 parallel calls: all < 0.3 s). Hypotheses: CT 110's bind mounts on the
# HDD spinning up; the laptops' NICs (~2 ms to the hEX). A failed plan is
# safe to re-run.
provider "proxmox" {
  alias    = "pve2"
  endpoint = "https://${local.host.pve2.ip}:8006"
  insecure = true
}
