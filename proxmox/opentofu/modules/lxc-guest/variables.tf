variable "host" {
  description = "The guest's inventory entry (module.lab.hosts[\"<name>\"]): name, vmid, node, vlan_id, cidr, gateway."
  type = object({
    name    = string
    vmid    = number
    node    = string
    vlan_id = number
    cidr    = string
    gateway = string
  })
}

variable "description" {
  description = "PVE description (shown in the UI). Passed verbatim."
  type        = string
}

variable "tags" {
  description = "PVE tags. Convention: the service name + \"tofu\"."
  type        = list(string)
}

variable "template_file_id" {
  description = "LXC template on the guest's node (a proxmox_download_file id)."
  type        = string
}

variable "ssh_public_key" {
  description = "Admin public key injected for root."
  type        = string
}

variable "cores" {
  description = "CPU cores."
  type        = number
  default     = 1
}

variable "memory_mb" {
  description = "Dedicated memory, MB."
  type        = number
  default     = 512
}

variable "swap_mb" {
  description = "Swap, MB."
  type        = number
  default     = 512
}

variable "disk_gb" {
  description = "Root disk, GB, on local-lvm (thin)."
  type        = number
  default     = 4
}

variable "start_on_boot" {
  description = "Start with the node. False only for guests that cannot start unattended (e.g. hand-mounted sources)."
  type        = bool
  default     = true
}

variable "migrate" {
  description = "Allow a node change to migrate the guest (offline). False when it is pinned by host bind mounts or devices."
  type        = bool
  default     = true
}

variable "dns_domain" {
  description = "Search domain."
  type        = string
  default     = "home.arpa"
}
