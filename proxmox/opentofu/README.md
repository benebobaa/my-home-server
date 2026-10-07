# Proxmox guests — OpenTofu (bpg/proxmox)

Declarative provisioning for the lab's guests, using the community
[`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest)
provider. The router is already IaC (`network/routeros/`); this stack brings
the Proxmox side (containers today, VMs later) under the same discipline.

## What this manages

| Resource | Purpose |
| --- | --- |
| `admin-gw` (CT 101) | Tailscale subnet router — remote lab management. See `services/admin-gw/`. |
| Debian 13 template | Downloaded to `local` (vztmpl) and referenced by the container. |

**Not** managed here: the nodes themselves (golden configs + runbooks in
`proxmox/`) and the switch (config backup in `network/switch/`).

## Prerequisites

- `local` storage accepts `vztmpl`; `local-lvm` (thin) exists for rootfs.
- An API token with enough privileges — one-time setup, run on any node:

  ```bash
  pveum user add terraform@pve --comment "OpenTofu guest provisioning"
  pveum acl modify / --users terraform@pve --roles PVEAdmin
  pveum acl modify /storage --users terraform@pve --roles PVEDatastoreAdmin
  pveum role add TofuNetworkAccess --privs "Sys.AccessNetwork"   # fetch template URLs
  pveum acl modify /nodes --users terraform@pve --roles TofuNetworkAccess
  pveum user token add terraform@pve tofu --privsep 0   # copy the secret!
  ```

- `.env` with the token (git-ignored), see `.env.example`.

## Usage

```bash
cd proxmox/opentofu
set -a; source .env; set +a    # PROXMOX_VE_API_TOKEN
tofu init
tofu plan
tofu apply
```

On apply, this stack will (idempotently):

1. download the Debian 13 LXC template to `local` (if missing),
2. create/update the `admin-gw` container (VLAN 10, static `10.10.10.15`,
   unprivileged, `onboot`),
3. run `services/admin-gw/provision.sh` inside it (installs Tailscale),
4. apply the root-only container config over SSH — the `/dev/net/tun`
   passthrough (PVE restricts `dev*` to root sessions — the API token cannot;
   step is idempotent) — and reboot the container. IP forwarding for subnet
   routing is set in-guest by `provision.sh` (`/etc/sysctl.d`).

## Notes

- State is local (`terraform.tfstate`) and git-ignored — single-operator
  homelab. Rebuild the token + `.env` if the machine is replaced.
- Secrets never live in HCL: the token comes from the environment only.
- Move the container between nodes by changing `admin_gw_node`
  (`migrate = true` → offline migration, short downtime; useful after the
  cluster exists).
- The interactive Tailscale login + route approval stay manual by design
  (account-level actions) — see `services/admin-gw/README.md`.
- `dev0` (TUN passthrough) is excluded from provider management
  (`ignore_changes`) — PVE only lets root sessions set it, so the
  `terraform_data.admin_gw_tun` step owns it. After editing
  `files/admin-gw-root-config.sh`, re-run the step with:
  `tofu apply -replace=terraform_data.admin_gw_tun`.
