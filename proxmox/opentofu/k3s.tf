# k3s — the VM for Kubeletto's tenant cluster (ADR 0004: tenants run
# arbitrary code, so a VM, never an LXC). DMZ (VLAN 25), 10.10.25.20.
#
# Interim on pve2 (2026-10-11): Kubeletto's rented server ends 2026-11-05 and
# pve1 is not built yet. When pve1 joins the cluster the VM moves there
# offline (`cpu.type = host` is fine for that; a live migration between the
# laptops' Intel and pve1's Ryzen would not be). K3s itself is installed in a
# later step; this file is the machine only.
#
# Everything in the guest goes through the pinned root SSH to the node and
# `qm guest exec` (the guest agent, installed by cloud-init) — never a direct
# SSH to the VM, whose host key changes on every rebuild.
#
# DMZ specifics: the hEX drops DNS from the DMZ (tenants must not enumerate
# home.arpa), so the VM resolves through public resolvers; no log shipping
# into MGMT (lab.yaml refuses logs: true there).

locals {
  k3s_ssh = local.node_ssh[local.host.k3s.node]

  k3s_user_data = templatefile("${path.module}/files/k3s-user-data.yaml.tftpl", {
    hostname       = local.host.k3s.name
    ssh_public_key = local.admin_ssh_public_key
  })
  k3s_user_data_file = "k3s-user-data.yaml"
}

# Debian 13 generic cloud image, a dated build pinned by the sha512 Debian
# publishes (SHA512SUMS next to it). Imported as the VM's disk.
resource "proxmox_download_file" "debian_13_cloud_pve2" {
  provider = proxmox.pve2 # direct: see provider.tf

  node_name          = "pve2"
  datastore_id       = "local"
  content_type       = "import"
  url                = "https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-genericcloud-amd64-20261001-2618.qcow2"
  checksum           = "f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d"
  checksum_algorithm = "sha512"
}

# The user-data snippet, written through the pinned root SSH (the provider
# has no SSH access of its own). Keyed on its content.
resource "terraform_data" "k3s_user_data" {
  triggers_replace = [sha256(local.k3s_user_data)]

  provisioner "local-exec" {
    command = "printf '%s' \"$USER_DATA\" | ${local.k3s_ssh} 'install -d /var/lib/vz/snippets && cat > /var/lib/vz/snippets/${local.k3s_user_data_file}'"

    environment = {
      USER_DATA = local.k3s_user_data
    }
  }
}

resource "proxmox_virtual_environment_vm" "k3s" {
  node_name = local.host.k3s.node
  vm_id     = local.host.k3s.vmid
  name      = local.host.k3s.name

  description = "k3s — Kubeletto tenant cluster (10.10.25.20, DMZ). Managed by OpenTofu: proxmox/opentofu."
  tags        = ["k3s", "kubeletto", "tofu"]

  on_boot         = true
  started         = true
  stop_on_destroy = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  # Kubernetes wants fixed memory (no ballooning). 5 GB to start: OpenObserve
  # and the abusive tenants stay behind; grow it before go-live if needed.
  memory {
    dedicated = 5120
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.debian_13_cloud_pve2.id
    interface    = "scsi0"
    size         = 40
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = local.host.k3s.vlan_id
    model   = "virtio"
  }

  # Cloud images have no VGA console: use the serial one.
  serial_device {}
  vga {
    type = "serial0"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-lvm"

    dns {
      servers = ["1.1.1.1", "9.9.9.9"]
    }

    ip_config {
      ipv4 {
        address = local.host.k3s.cidr
        gateway = local.host.k3s.gateway
      }
    }

    user_data_file_id = "local:snippets/${local.k3s_user_data_file}"
  }

  depends_on = [terraform_data.k3s_user_data]
}
