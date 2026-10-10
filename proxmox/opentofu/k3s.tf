# k3s — the VMs of Kubeletto's tenant cluster (ADR 0004: tenants run
# arbitrary code, so VMs, never LXCs). DMZ (VLAN 25): the server `k3s`
# (10.10.25.20, pve2) and the worker `k3s-worker` (10.10.25.21, pve3).
#
# Interim on pve2 (2026-10-11): Kubeletto's rented server ends 2026-11-05 and
# pve1 is not built yet. When pve1 joins the cluster the VM moves there
# offline (`cpu.type = host` is fine for that; a live migration between the
# laptops' Intel and pve1's Ryzen would not be). K3s itself is installed in a
# later step; this file is the machine only.
#
# Everything in the guest goes through the pinned root SSH to the node and
# `qm guest exec` (the guest agent, installed by cloud-init). The VM itself
# runs no SSH and holds no admin key (tenant code runs there).
#
# OPEN — must close before tenant workloads run here (the rehearsal): the
# NICs have the Proxmox firewall off, so nothing stops one VM claiming the
# other's address inside VLAN 25. The hEX's rp-filter only checks the
# interface, so the worker (where tenant code runs) could source traffic as
# 10.10.25.20 and pass the Postgres pinhole; pg_hba still demands the
# kubeletto password. Fix: per-VM firewall with ipfilter/macfilter (an
# ipfilter-net0 ipset holding each VM's address), which needs the
# datacenter firewall switched on with the hosts' own firewalls kept off —
# it touches the management path, so it is its own change.
#
# DMZ specifics: the hEX drops DNS from the DMZ (tenants must not enumerate
# home.arpa), so the VM resolves through public resolvers; no log shipping
# into MGMT (lab.yaml refuses logs: true there).

locals {
  # Both VMs of the cluster: the server (control plane + platform, pve2) and
  # the worker (tenant pods + builds, pve3 — stateless, which is pve3's rule).
  k3s_vms = ["k3s", "k3s-worker"]

  k3s_user_data = {
    for n in local.k3s_vms : n => templatefile("${path.module}/files/k3s-user-data.yaml.tftpl", {
      hostname = local.host[n].name
    })
  }
}

# Debian 13 generic cloud image, a dated build pinned by the sha512 Debian
# publishes (SHA512SUMS next to it). Imported as the VMs' disks, one copy per
# node.
resource "proxmox_download_file" "debian_13_cloud_pve2" {
  provider = proxmox.pve2 # direct: see provider.tf

  node_name          = "pve2"
  datastore_id       = "local"
  content_type       = "import"
  url                = "https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-genericcloud-amd64-20261001-2618.qcow2"
  checksum           = "f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d"
  checksum_algorithm = "sha512"
}

resource "proxmox_download_file" "debian_13_cloud_pve3" {
  node_name          = "pve3" # the provider's endpoint: no proxying involved
  datastore_id       = "local"
  content_type       = "import"
  url                = "https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-genericcloud-amd64-20261001-2618.qcow2"
  checksum           = "f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d"
  checksum_algorithm = "sha512"
}

# Each VM's user-data snippet on its node, written through the pinned root
# SSH (the provider has no SSH access of its own). Keyed on its content.
resource "terraform_data" "k3s_user_data" {
  for_each = local.k3s_user_data

  triggers_replace = [sha256(each.value)]

  provisioner "local-exec" {
    command = "printf '%s' \"$USER_DATA\" | ${local.node_ssh[local.host[each.key].node]} 'install -d /var/lib/vz/snippets && cat > /var/lib/vz/snippets/${each.key}-user-data.yaml'"

    environment = {
      USER_DATA = each.value
    }
  }
}

moved {
  from = terraform_data.k3s_user_data
  to   = terraform_data.k3s_user_data["k3s"]
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

    user_data_file_id = "local:snippets/k3s-user-data.yaml"
  }

  depends_on = [terraform_data.k3s_user_data]
}

# The worker: same machine shape, smaller, on pve3. Holds nothing worth
# keeping (images re-pull, pods reschedule), so its disk is left out of the
# PBS backup: it stays in the nightly job (no PveGuestNotBackedUp) at no
# datastore cost.
resource "proxmox_virtual_environment_vm" "k3s_worker" {
  node_name = local.host["k3s-worker"].node
  vm_id     = local.host["k3s-worker"].vmid
  name      = local.host["k3s-worker"].name

  description = "k3s-worker — Kubeletto tenant cluster, K3s agent for tenant pods and builds (10.10.25.21, DMZ). Managed by OpenTofu: proxmox/opentofu."
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

  memory {
    dedicated = 3072
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = proxmox_download_file.debian_13_cloud_pve3.id
    interface    = "scsi0"
    size         = 30
    discard      = "on"
    iothread     = true
    ssd          = true
    backup       = false
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = local.host["k3s-worker"].vlan_id
    model   = "virtio"
  }

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
        address = local.host["k3s-worker"].cidr
        gateway = local.host["k3s-worker"].gateway
      }
    }

    user_data_file_id = "local:snippets/k3s-worker-user-data.yaml"
  }

  depends_on = [terraform_data.k3s_user_data]
}

# --- K3s on the VMs (services/k3s/install.sh) ---------------------------------
# Join tokens, generated here (encrypted state). The server token joins
# control-plane nodes — cluster admin — and stays on `k3s` only. The agent
# token joins workers only; it is all `k3s-worker` (tenant code) ever gets.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "random_password" "k3s_agent_token" {
  length  = 48
  special = false
}

locals {
  k3s_install_sha = filesha256("${path.module}/../../services/k3s/install.sh")

  # Pipe the token lines + the script into the guest (agent stdin, never
  # argv), then print the guest's output and fail on its exit code. Only the
  # server's environment carries K3S_TOKEN.
  k3s_guest_exec = {
    for n in local.k3s_vms : n => join(" ", [
      "{ [ -z \"$${K3S_TOKEN:-}\" ] || printf 'K3S_TOKEN=%s\\n' \"$K3S_TOKEN\"; printf 'K3S_AGENT_TOKEN=%s\\n' \"$K3S_AGENT_TOKEN\"; cat ${path.module}/../../services/k3s/install.sh; }",
      "| ${local.node_ssh[local.host[n].node]}",
      "'qm guest exec ${local.host[n].vmid} --pass-stdin 1 --timeout 900 -- bash -s -- ${n == "k3s" ? "server" : "agent ${local.host.k3s.ip}"}",
      "| python3 -c \"import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get(chr(111)+\\\"ut-data\\\",\\\"\\\")); sys.stderr.write(d.get(chr(101)+\\\"rr-data\\\",\\\"\\\")); sys.exit(d.get(chr(101)+\\\"xitcode\\\",1))\"'",
    ])
  }
}

resource "terraform_data" "k3s_server" {
  triggers_replace = [
    local.k3s_install_sha,
    sha256("${random_password.k3s_token.result}/${random_password.k3s_agent_token.result}"),
    proxmox_virtual_environment_vm.k3s.network_device[0].mac_address,
  ]

  provisioner "local-exec" {
    command = local.k3s_guest_exec["k3s"]
    environment = {
      K3S_TOKEN       = random_password.k3s_token.result
      K3S_AGENT_TOKEN = random_password.k3s_agent_token.result
    }
  }
}

resource "terraform_data" "k3s_worker" {
  triggers_replace = [
    local.k3s_install_sha,
    sha256(random_password.k3s_agent_token.result),
    proxmox_virtual_environment_vm.k3s_worker.network_device[0].mac_address,
  ]

  provisioner "local-exec" {
    command     = local.k3s_guest_exec["k3s-worker"]
    environment = { K3S_AGENT_TOKEN = random_password.k3s_agent_token.result }
  }

  depends_on = [terraform_data.k3s_server]
}
