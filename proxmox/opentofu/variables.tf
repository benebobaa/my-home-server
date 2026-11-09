variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. Pre-cluster this is pve3; after clustering, any node works."
  type        = string
  default     = "https://10.10.10.13:8006"
}

variable "admin_ssh_public_key_path" {
  description = "Admin public key injected into new guests."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_ssh_private_key_path" {
  description = "Matching private key, used by the provisioning connection."
  type        = string
  default     = "~/.ssh/id_ed25519"
  # A path, not a secret: marking it sensitive blanked every provisioner's
  # output (ADR 0007).
}

variable "archive_bene_password" {
  description = "File Browser password for user bene (from secrets.sops.env)."
  type        = string
  sensitive   = true
}

variable "archive_irene_password" {
  description = "File Browser password for user irene (from secrets.sops.env)."
  type        = string
  sensitive   = true
}

variable "monitoring_telegram_bot_token" {
  description = "Telegram bot token for alerts (from secrets.sops.env). Empty until the operator creates the bot: alerts then go nowhere."
  type        = string
  sensitive   = true
  default     = ""
}

variable "monitoring_telegram_chat_id" {
  description = "Telegram chat id that receives alerts (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "monitoring_healthchecks_ping_url" {
  description = "healthchecks.io ping URL for the Watchdog dead-man's switch (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "monitoring_grafana_admin_password" {
  description = "Grafana admin password (from secrets.sops.env)."
  type        = string
  sensitive   = true
}

variable "monitoring_snmp_auth_password" {
  description = "SNMPv3 auth password of the hEX user `monitoring` — same value as network/routeros TF_VAR_snmp_auth_password (from secrets.sops.env)."
  type        = string
  sensitive   = true
}

variable "monitoring_snmp_priv_password" {
  description = "SNMPv3 privacy password of the hEX user `monitoring` — same value as network/routeros TF_VAR_snmp_priv_password (from secrets.sops.env)."
  type        = string
  sensitive   = true
}


# The off-site copy of the shared Postgres (ADR 0034): a Backblaze B2 bucket
# over its S3 API. All empty until the operator adds them to secrets.sops.env;
# terraform_data.postgres_offsite does nothing until then. The bucket's name
# and endpoint are not secret, but they stay out of this public repo.
variable "postgres_b2_key_id" {
  description = "B2 application key ID (read+write, this bucket only) that CT 130 archives with (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_b2_app_key" {
  description = "The B2 application key itself (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_b2_bucket" {
  description = "B2 bucket name, private (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_b2_endpoint" {
  description = "B2 S3 endpoint host, e.g. s3.<region>.backblazeb2.com, without https:// (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_b2_region" {
  description = "B2 region, the <region> part of the endpoint (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_offsite_cipher_pass" {
  description = "pgBackRest repo cipher passphrase (aes-256-cbc), at least 32 characters; without it the bucket cannot be read (from secrets.sops.env)."
  type        = string
  sensitive   = true
  default     = ""
}
