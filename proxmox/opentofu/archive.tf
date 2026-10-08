# archive — read-only web access (File Browser) to the family archive for
# Bene and Irene, reachable only over Tailscale (node sharing), never public.
# Why not Cloudflare Tunnel: docs/decisions/0005-family-archive-over-tailscale.md
#
# Service notes: services/archive/README.md
# The hEX already lets VLAN 20 reach the internet ("internet for the lab") and
# admin-gw reach VLAN 20 ("admin-gw to internal") — no router changes needed.

resource "proxmox_download_file" "debian_13_template_pve2" {
  node_name    = "pve2"
  datastore_id = "local"
  content_type = "vztmpl"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  # pve2 already had this template from an earlier hand-made test CT; adopt it.
  overwrite_unmanaged = true
}

resource "proxmox_virtual_environment_container" "archive" {
  node_name = "pve2"
  vm_id     = 110

  description = "archive — File Browser (read-only) over Tailscale for the family archive. Managed by OpenTofu: proxmox/opentofu."
  tags        = ["archive", "tofu"]

  unprivileged = true
  # Bind mounts pin it to pve2.
  migrate = false
  # Not boot-safe yet: its mount sources (/mnt/staging = thin LV
  # rescue-staging, /mnt/e4 = pve2 HDD sda4) are mounted by hand, not in fstab.
  # Flip to true once the archive lives on ZFS (services/archive/README.md).
  start_on_boot = false

  features {
    nesting = true
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 256
  }

  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  # NOTE: the archive bind mounts (mp0/mp1, read-only) and /dev/net/tun (dev0)
  # are applied after creation by terraform_data.archive_root_config below —
  # PVE allows host bind mounts and device passthrough only for root@pam.

  initialization {
    hostname = "archive"

    dns {
      domain  = "home.arpa"
      servers = ["10.10.20.1"]
    }

    ip_config {
      ipv4 {
        address = "10.10.20.30/24"
        gateway = "10.10.20.1"
      }
    }

    user_account {
      keys = [trimspace(file(pathexpand(var.admin_ssh_public_key_path)))]
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr0"
    vlan_id = 20
  }

  operating_system {
    template_file_id = proxmox_download_file.debian_13_template_pve2.id
    type             = "debian"
  }

  wait_for_ip {
    ipv4 = true
  }

  lifecycle {
    # mp*/dev0 are applied out-of-band (root-only), see below.
    ignore_changes = [mount_point, device_passthrough]
  }

  # One-time in-guest bootstrap: Tailscale + File Browser + the two users.
  # The operator Mac has no route to VLAN 20, so connect through admin-gw.
  provisioner "file" {
    content     = "BENE_PASSWORD=${var.archive_bene_password}\nIRENE_PASSWORD=${var.archive_irene_password}\n"
    destination = "/root/archive-users.env"

    connection {
      type                = "ssh"
      host                = "10.10.20.30"
      user                = "root"
      private_key         = file(pathexpand(var.admin_ssh_private_key_path))
      bastion_host        = "10.10.10.15"
      bastion_user        = "root"
      bastion_private_key = file(pathexpand(var.admin_ssh_private_key_path))
      timeout             = "3m"
    }
  }

  provisioner "file" {
    source      = "${path.module}/../../services/archive/provision.sh"
    destination = "/root/provision-archive.sh"

    connection {
      type                = "ssh"
      host                = "10.10.20.30"
      user                = "root"
      private_key         = file(pathexpand(var.admin_ssh_private_key_path))
      bastion_host        = "10.10.10.15"
      bastion_user        = "root"
      bastion_private_key = file(pathexpand(var.admin_ssh_private_key_path))
      timeout             = "3m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /root/archive-users.env",
      "bash /root/provision-archive.sh",
    ]

    connection {
      type                = "ssh"
      host                = "10.10.20.30"
      user                = "root"
      private_key         = file(pathexpand(var.admin_ssh_private_key_path))
      bastion_host        = "10.10.10.15"
      bastion_user        = "root"
      bastion_private_key = file(pathexpand(var.admin_ssh_private_key_path))
      timeout             = "3m"
    }
  }
}

# PVE root-only step: read-only bind mounts of the archive + TUN passthrough,
# then reboot the container. Idempotent; script: files/archive-root-config.sh.
resource "terraform_data" "archive_root_config" {
  triggers_replace = [
    proxmox_virtual_environment_container.archive.vm_id,
    filesha256("${path.module}/files/archive-root-config.sh"),
  ]

  provisioner "local-exec" {
    command = "ssh -i ${pathexpand(var.admin_ssh_private_key_path)} -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@${var.archive_node_ssh_host} 'bash -s' < ${path.module}/files/archive-root-config.sh"
  }
}
