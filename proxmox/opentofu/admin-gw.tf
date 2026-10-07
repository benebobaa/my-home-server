# admin-gw — the Tailscale subnet router that makes the lab manageable from
# anywhere (no inbound ports at home; see docs/design/network-design.md).
#
# Service notes: services/admin-gw/README.md
# The hEX already allows 10.10.10.15 (firewall address-list "admin-gw") into
# the lab — no router changes needed for this stack.

resource "proxmox_download_file" "debian_13_template" {
  node_name    = var.admin_gw_node
  datastore_id = "local"
  content_type = "vztmpl"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
}

resource "proxmox_virtual_environment_container" "admin_gw" {
  node_name = var.admin_gw_node
  vm_id     = 101

  description = "admin-gw — Tailscale subnet router (advertises 10.10.10.0/24, 192.168.99.0/29). Managed by OpenTofu: proxmox/opentofu."
  tags        = ["admin", "tofu"]

  unprivileged  = true
  start_on_boot = true
  migrate       = true

  features {
    nesting = true
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 3
  }

  # NOTE: the /dev/net/tun passthrough (dev0) is applied after creation by
  # terraform_data.admin_gw_tun below — PVE allows device passthrough only for
  # genuine root@pam sessions, not API tokens (same class of limitation as
  # lxc.idmap, which the provider itself applies via SSH).

  initialization {
    hostname = "admin-gw"

    dns {
      domain  = "home.arpa"
      servers = ["10.10.10.1"]
    }

    ip_config {
      ipv4 {
        address = "10.10.10.15/24"
        gateway = "10.10.10.1"
      }
    }

    user_account {
      keys = [trimspace(file(pathexpand(var.admin_ssh_public_key_path)))]
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 10
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_13_template.id
    type             = "debian"
  }

  wait_for_ip {
    ipv4 = true
  }

  lifecycle {
    # dev0 is applied out-of-band by terraform_data.admin_gw_tun below
    # (root-only in PVE). The provider reads it back from the container, so
    # ignore it here — otherwise plans try to add/remove it via the API,
    # which the token is not allowed to do.
    ignore_changes = [device_passthrough]
  }

  # One-time in-guest bootstrap (installs Tailscale). The interactive
  # `tailscale up` login + route approval are account-level and happen by
  # hand once — see services/admin-gw/README.md.
  provisioner "file" {
    source      = "${path.module}/../../services/admin-gw/provision.sh"
    destination = "/root/provision-admin-gw.sh"

    connection {
      type        = "ssh"
      host        = "10.10.10.15"
      user        = "root"
      private_key = file(pathexpand(var.admin_ssh_private_key_path))
      timeout     = "3m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 755 /root/provision-admin-gw.sh",
      "bash /root/provision-admin-gw.sh",
    ]

    connection {
      type        = "ssh"
      host        = "10.10.10.15"
      user        = "root"
      private_key = file(pathexpand(var.admin_ssh_private_key_path))
      timeout     = "3m"
    }
  }
}

# PVE root-only step: TUN passthrough for the container (API tokens cannot
# write dev* config), then reboot it. Idempotent; script:
# files/admin-gw-root-config.sh.
resource "terraform_data" "admin_gw_tun" {
  triggers_replace = [proxmox_virtual_environment_container.admin_gw.vm_id]

  provisioner "local-exec" {
    command = "ssh -i ${pathexpand(var.admin_ssh_private_key_path)} -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@${var.node_ssh_host} 'bash -s' < ${path.module}/files/admin-gw-root-config.sh"
  }
}
