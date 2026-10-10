terraform {
  required_version = ">= 1.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116"
    }
    # App database passwords (postgres.tf).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
