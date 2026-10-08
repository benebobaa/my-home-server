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
tofu init
sops exec-env secrets.sops.env 'tofu plan'    # review
sops exec-env secrets.sops.env 'tofu apply'   # commit to the device
```

Credentials (`ROS_USERNAME`, `ROS_PASSWORD`) and the state passphrase live in
`secrets.sops.env` (encrypted, committed — `sops edit secrets.sops.env`).
State is encrypted (`encryption.tf`, enforced) and committed. See
[`docs/runbooks/secrets.md`](../../docs/runbooks/secrets.md). Provider:
`terraform-routeros/routeros`, REST at `https://192.168.99.1` by default
(self-signed → `insecure = true`). If your laptop is on the OOB port instead:
`tofu apply -var ros_hosturl=https://192.168.88.1`.

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
- Snapshot: `../../scripts/hex-snapshot.sh` (add `ROS_HOST=192.168.88.1` when on the OOB port)
