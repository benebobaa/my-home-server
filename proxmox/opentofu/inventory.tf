# Addresses, VMIDs and placement come from inventory/lab.yaml (ADR 0007) —
# never typed here.
module "lab" {
  source = "../../inventory"
}

locals {
  host = module.lab.hosts

  # Root SSH to each node (host key pinned in the operator's known_hosts):
  # used for pct exec and the root-only PVE steps.
  node_ssh = {
    for n, h in module.lab.hosts : n =>
    "ssh -i ${pathexpand(var.admin_ssh_private_key_path)} -o BatchMode=yes -o StrictHostKeyChecking=yes root@${h.ip}"
    if h.kind == "node"
  }

  admin_ssh_public_key = trimspace(file(pathexpand(var.admin_ssh_public_key_path)))
}
