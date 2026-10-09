# modules/lxc-guest

One unprivileged Debian LXC on the lab's conventions (ADR 0007). It takes the
guest's `inventory/lab.yaml` entry and builds:
- a static IP on its VLAN, with the hEX as gateway and resolver,
- `home.arpa` as the search domain,
- nesting on, root disk on `local-lvm`,
- the admin SSH key.

```hcl
module "monitoring" {
  source = "./modules/lxc-guest"

  host             = local.host.monitoring
  description      = "monitoring — … Managed by OpenTofu: proxmox/opentofu."
  tags             = ["monitoring", "tofu"]
  template_file_id = proxmox_download_file.debian_13_template_pve2.id
  ssh_public_key   = local.admin_ssh_public_key
  cores            = 2
  memory_mb        = 1536
  disk_gb          = 12
}
```

**The container only.** Provisioning differs per service, so it stays in the
service's `.tf` file:
- in-guest setup via `pct exec`,
- root-only host steps (bind mounts, `dev*` passthrough: ignored here,
  because the API token cannot set them),
- secrets over the node's pinned root SSH.

Key those steps on **`generation`**, which changes only when the container is
recreated (it is the MAC address PVE generates). Don't use
`replace_triggered_by` on the container: that also fires on in-place updates,
such as a stopped CT flipping `started`.

Outputs: `vmid`, `node`, `ip`, `generation`.
