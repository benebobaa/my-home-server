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
  # Published in Proxmox's appliance index (aplinfo); plain-HTTP download, so verify.
  checksum           = "4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b"
  checksum_algorithm = "sha512"
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

  # One-time in-guest bootstrap: Tailscale + File Browser (no secrets).
  # The operator Mac has no route to VLAN 20, so connect through admin-gw.
  # Users/passwords are NOT sent this way: see terraform_data.archive_users.
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
    filesha256("${path.module}/files/archive-root-config.sh"),
  ]

  # vm_id survives a container replacement, so trigger on the resource itself.
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_container.archive]
  }

  provisioner "local-exec" {
    command = "ssh -i ${pathexpand(var.admin_ssh_private_key_path)} -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@${var.archive_node_ssh_host} 'bash -s' < ${path.module}/files/archive-root-config.sh"
  }
}

# File Browser users (bene, irene; download-only). Passwords come from
# secrets.sops.env and travel only over the root SSH to pve2 — host key pinned
# in the operator's known_hosts — then `pct exec` into the CT; never over the
# provisioner connection above (no host-key check for a brand-new CT).
resource "terraform_data" "archive_users" {
  triggers_replace = [
    sha256("${var.archive_bene_password}:${var.archive_irene_password}"),
    filesha256("${path.module}/../../services/archive/users.sh"),
  ]

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_container.archive]
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      SSH="ssh -i ${pathexpand(var.admin_ssh_private_key_path)} -o BatchMode=yes -o StrictHostKeyChecking=yes root@${var.archive_node_ssh_host}"
      $SSH 'pct exec 110 -- sh -c "cat > /usr/local/sbin/archive-users.sh && chmod 0700 /usr/local/sbin/archive-users.sh"' < ${path.module}/../../services/archive/users.sh
      printf 'BENE_PASSWORD=%s\nIRENE_PASSWORD=%s\n' "$BENE_PASSWORD" "$IRENE_PASSWORD" | $SSH 'pct exec 110 -- /usr/local/sbin/archive-users.sh'
    EOT

    environment = {
      BENE_PASSWORD  = var.archive_bene_password
      IRENE_PASSWORD = var.archive_irene_password
    }
  }

  depends_on = [terraform_data.archive_root_config]
}
