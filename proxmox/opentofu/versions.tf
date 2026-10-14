terraform {
  required_version = ">= 1.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.116"
    }
    # App database passwords (postgres.tf), NATS and Valkey passwords.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    # The shared NATS's TLS certificate (nats.tf).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }
}
