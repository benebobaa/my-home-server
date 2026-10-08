terraform {
  required_version = ">= 1.8" # state encryption with variables

  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "~> 1.99"
    }
  }
}
