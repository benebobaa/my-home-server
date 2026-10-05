# hEX — MikroTik RB750Gr3 (RouterOS 7)

OpenTofu stack for the lab router.
Design: [`../../docs/design/network-design.md`](../../docs/design/network-design.md).

## Port roles (as cabled)

| Port | Role |
| --- | --- |
| ether1 | WAN — uplink to the Biznet router (DHCP client) |
| ether2 | spare |
| ether3 | OOB management — direct laptop / recovery (`192.168.88.1/24`) |
| ether4 | spare |
| ether5 | trunk to switch P8 (VLANs 10/20/25/30/40/50 tagged + VLAN 1 native) |

## Workflow

```sh
cd network/routeros
set -a; source .env; set +a    # ROS_USERNAME / ROS_PASSWORD
tofu init
tofu plan                      # review
tofu apply                     # commit to the device
```

State is local (`terraform.tfstate`, git-ignored). Provider:
`terraform-routeros/routeros`, REST at `https://192.168.88.1` (self-signed →
`insecure = true`).

## Contents

| Path | What |
| --- | --- |
| `bootstrap.rsc` / `bootstrap.local.rsc` | access-layer bootstrap (see runbook) |
| `snapshots/` | `/export` dumps, taken before/after changes |
| `versions.tf`, `provider.tf`, `variables.tf` | stack scaffolding |
| `interfaces.tf` | WAN port, VLANs on the `ether5` trunk, interface lists |
| `addressing.tf` | gateways + WAN DHCP client |
| `dhcp.tf` | DHCP pools/servers for VLANs 30/40/50 |
| `firewall.tf` | address lists, input/forward filter, NAT, MSS clamp |

## Procedures

- Reset + bootstrap: [`../../docs/runbooks/hex-bootstrap.md`](../../docs/runbooks/hex-bootstrap.md)
- Snapshot: `../../scripts/hex-snapshot.sh`
