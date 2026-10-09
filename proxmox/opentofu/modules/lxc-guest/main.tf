# One unprivileged Debian LXC on the lab's conventions (ADR 0007): static IP
# on its VLAN from inventory/lab.yaml, the hEX as gateway and resolver,
# nesting on (systemd in unprivileged CTs), root disk on local-lvm.
#
# The container only. Provisioning (in-guest setup, root-only host steps,
# secrets) stays with each service: key it on `generation` so it re-runs when
# the container is recreated — not on every in-place change.

resource "proxmox_virtual_environment_container" "this" {
  node_name = var.host.node
  vm_id     = var.host.vmid

  description = var.description
  tags        = var.tags

  unprivileged  = true
  start_on_boot = var.start_on_boot
  migrate       = var.migrate

  features {
    nesting = true
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.disk_gb
  }

  initialization {
    hostname = var.host.name

    dns {
      domain  = var.dns_domain
      servers = [var.host.gateway]
    }

    ip_config {
      ipv4 {
        address = var.host.cidr
        gateway = var.host.gateway
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = var.host.vlan_id
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }

  wait_for_ip {
    ipv4 = true
  }

  lifecycle {
    # Bind mounts (mp*) and device passthrough (dev*) are root@pam-only in
    # PVE: services set them with a root SSH step, so the API token must not
    # try to manage them.
    ignore_changes = [mount_point, device_passthrough]
  }
}
