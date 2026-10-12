# ai — the on-demand AI workstation VM on pve1 (ADR 0012): Ubuntu 24.04 with
# the RTX 3060 by passthrough, on the LAB VLAN (internet only).
#
# No provider resource on pve1, on purpose: pve1 is off most days and the
# PVE API cannot read an offline node, so a bpg resource there would break
# every plan. These terraform_data resources read nothing remote at plan
# time; they run only when their scripts or inventory values change, and
# such an apply needs pve1 up. Plan does not see drift inside the VM;
# re-running the scripts converges it (services/ai/README.md).
#
#   ai_user_data  cloud-init user-data snippet on pve1 (the admin key's user)
#   ai_vm         create/converge the VM, GPU passthrough (services/ai/vm.sh)
#   ai_converge   in-guest setup through the agent (services/ai/converge.sh)

locals {
  ai_dir  = "${path.module}/../../services/ai"
  ai_ssh  = local.node_ssh[local.host.ai.node]
  ai_user = "bene" # the operator's login in the VM

  ai_user_data = templatefile("${local.ai_dir}/user-data.yaml.tftpl", {
    hostname       = local.host.ai.name
    user           = local.ai_user
    ssh_public_key = local.admin_ssh_public_key
  })
}

resource "terraform_data" "ai_user_data" {
  triggers_replace = [sha256(local.ai_user_data)]

  provisioner "local-exec" {
    command = "printf '%s' \"$USER_DATA\" | ${local.ai_ssh} 'install -d /var/lib/vz/snippets && cat > /var/lib/vz/snippets/${local.host.ai.name}-user-data.yaml'"

    environment = {
      USER_DATA = local.ai_user_data
    }
  }
}

resource "terraform_data" "ai_vm" {
  triggers_replace = [
    filesha256("${local.ai_dir}/vm.sh"),
    local.host.ai.vmid,
    local.host.ai.cidr,
    local.host.ai.gateway,
    local.host.ai.vlan_id,
  ]

  provisioner "local-exec" {
    command = "${local.ai_ssh} 'bash -s -- ${local.host.ai.vmid} ${local.host.ai.name} ${local.host.ai.cidr} ${local.host.ai.gateway} ${local.host.ai.vlan_id}' < ${local.ai_dir}/vm.sh"
  }

  depends_on = [terraform_data.ai_user_data]
}

resource "terraform_data" "ai_converge" {
  triggers_replace = [
    filesha256("${local.ai_dir}/converge.sh"),
    filesha256("${local.ai_dir}/provision.sh"),
    filesha256("${local.logs_dir}/ship.sh"),
    local.logs_journald_url,
    terraform_data.ai_vm.id,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata \
          -C ${local.ai_dir} -cf - converge.sh provision.sh \
          -C ${abspath(local.logs_dir)} ship.sh \
        | ${local.ai_ssh} 'rm -rf /root/ai && mkdir -p /root/ai && tar -xf - -C /root/ai'
      ${local.ai_ssh} 'bash /root/ai/converge.sh ${local.host.ai.vmid} ${local.ai_user} ${local.logs_journald_url}'
    EOT
  }
}
