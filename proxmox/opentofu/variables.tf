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
