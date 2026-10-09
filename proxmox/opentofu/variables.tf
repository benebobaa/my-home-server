variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. Pre-cluster this is pve3; after clustering, any node works."
  type        = string
  default     = "https://10.10.10.13:8006"
}

variable "admin_gw_node" {
  description = "Node hosting the admin-gw container (changing it later migrates the container)."
  type        = string
  default     = "pve3"
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
  sensitive   = true
}

variable "node_ssh_host" {
  description = "SSH address of the node hosting admin-gw (root login, key auth); used for the root-only TUN passthrough step."
  type        = string
  default     = "10.10.10.13"
}

variable "archive_node_ssh_host" {
  description = "SSH address of the node hosting the archive container (root login, key auth); used for its root-only bind mounts + TUN step."
  type        = string
  default     = "10.10.10.12"
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

variable "monitoring_node_ssh_host" {
  description = "SSH address of the node hosting the monitoring container (root login, key auth); used for pct exec and the root-only PVE token/notification steps."
  type        = string
  default     = "10.10.10.12"
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
