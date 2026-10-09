# inventory — the lab's hosts and addresses

[`lab.yaml`](lab.yaml) is the single source of truth for VLANs, host IPs,
VMIDs and node placement ([ADR 0007](../docs/decisions/0007-repo-architecture-for-growth.md)).
The conventions (VMID ranges, IP ranges, `status`, `dns`) are at the top of
the file.

`main.tf` is a provider-less OpenTofu module that loads and validates it.
Plans fail with a message naming the offender on:
- a duplicate IP or VMID,
- an IP outside its VLAN, or a VLAN outside the supernet,
- an unknown VLAN, kind or status,
- a live guest without `vmid`/`node`, or a `node` that isn't a node host.

| Consumer | Uses |
| --- | --- |
| `network/routeros` | VLAN ids, gateways, DHCP ranges; DNS records (`dns_records`); address lists, DMZ pinhole, SNMP client |
| `proxmox/opentofu` | guest VMID, node, VLAN, IP/prefix, gateway (`modules/lxc-guest`); node SSH targets |
| planned | Ansible inventory, Prometheus targets |

Check it without secrets: `make inventory` (part of `make check`).
