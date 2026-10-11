# Cloudflare Tunnel for Kubeletto at home (ADR 0004): cloudflared runs inside
# the tenant cluster (K3s, DMZ) and dials out — no inbound ports at home.
#
# Remote-managed (config_src = "cloudflare"): the ingress rules below live at
# Cloudflare and reach the connectors live; changing them is an apply, not a
# pod restart. The connector itself is services/cloudflared/, deployed below.
#
# Not public yet: a hostname only reaches the tunnel once its DNS record is a
# CNAME to <tunnel id>.cfargotunnel.com (records.tf). Until cutover those
# records still point at the rented server.
#
# Destroy: Cloudflare refuses to delete a tunnel with live connections —
# scale the Deployment to 0 first (services/cloudflared/README.md).

locals {
  account_id = "f650e5eb59b56b70048a841520541189" # not secret

  # Kubeletto's Traefik (its websecure entrypoint; :80 only redirects to
  # https). match_sn_ito_host sends the request's hostname as SNI, which
  # Traefik's sniStrict needs; Traefik serves Cloudflare Origin CA certs, so
  # cloudflared verifies them against the Origin roots the connector mounts
  # (services/cloudflared/deploy.sh, ConfigMap origin-ca).
  traefik = "https://traefik.traefik.svc.cluster.local:443"
  to_traefik = {
    match_sn_ito_host = true
    ca_pool           = "/etc/cloudflared/origin-ca/origin-ca.pem"
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "kubeletto" {
  account_id = local.account_id
  name       = "kubeletto-home"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "kubeletto" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id

  config = {
    # domains.kubeletto.app (tenants' custom domains) is deliberately absent:
    # open decision, README "Records that matter for the move".
    ingress = [
      {
        hostname       = "api.kubeletto.com"
        service        = local.traefik
        origin_request = local.to_traefik
      },
      # Rehearsal (docs/design/kubeletto-home.md phase 1): the home copy on a
      # name prod does not use. Remove at cutover with its DNS record below.
      {
        hostname       = "home-api.kubeletto.com"
        service        = local.traefik
        origin_request = local.to_traefik
      },
      {
        hostname       = "*.kubeletto.app"
        service        = local.traefik
        origin_request = local.to_traefik
      },
      { service = "http_status:404" },
    ]
  }
}

# --- Rehearsal names --------------------------------------------------------
# Only these two names point at the tunnel before cutover; everything else
# (records.tf) still goes to the rented server. probe-rehearsal is a more
# specific name than the *.kubeletto.app wildcard, so it wins for itself only.
resource "cloudflare_dns_record" "rehearsal" {
  for_each = {
    "home-api.kubeletto.com"        = local.zone_id.com
    "probe-rehearsal.kubeletto.app" = local.zone_id.app
  }
  zone_id = each.value
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id}.cfargotunnel.com"
  ttl     = 1
  proxied = true
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "kubeletto" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.kubeletto.id
}

# --- The connector in the cluster ---------------------------------------------
# Through the pinned root SSH to the node and the guest agent (same path as
# proxmox/opentofu/k3s.tf): the token line + deploy.sh on stdin, never argv.
# The token holder can serve every hostname routed above, so it goes only to
# the server node `k3s` (no tenant code; services/k3s/README.md).

module "lab" {
  source = "../../inventory"
}

variable "admin_ssh_private_key_path" {
  description = "Operator key for the root SSH to the Proxmox nodes (as in proxmox/opentofu)."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

locals {
  k3s_server = module.lab.hosts.k3s
  # Same pinned SSH as proxmox/opentofu/inventory.tf.
  k3s_node_ssh       = "ssh -i ${pathexpand(var.admin_ssh_private_key_path)} -o BatchMode=yes -o StrictHostKeyChecking=yes root@${module.lab.hosts[local.k3s_server.node].ip}"
  cloudflared_deploy = "${path.module}/../../services/cloudflared/deploy.sh"
}

resource "terraform_data" "cloudflared" {
  triggers_replace = [
    filesha256(local.cloudflared_deploy),
    sha256(data.cloudflare_zero_trust_tunnel_cloudflared_token.kubeletto.token),
  ]

  provisioner "local-exec" {
    command = join(" ", [
      "{ printf 'TUNNEL_TOKEN=%s\\n' \"$TUNNEL_TOKEN\"; cat ${local.cloudflared_deploy}; }",
      "| ${local.k3s_node_ssh}",
      "'qm guest exec ${local.k3s_server.vmid} --pass-stdin 1 --timeout 300 -- bash -s",
      "| python3 -c \"import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get(chr(111)+\\\"ut-data\\\",\\\"\\\")); sys.stderr.write(d.get(chr(101)+\\\"rr-data\\\",\\\"\\\")); sys.exit(d.get(chr(101)+\\\"xitcode\\\",1))\"'",
    ])
    environment = {
      TUNNEL_TOKEN = data.cloudflare_zero_trust_tunnel_cloudflared_token.kubeletto.token
    }
  }

  depends_on = [cloudflare_zero_trust_tunnel_cloudflared_config.kubeletto]
}
