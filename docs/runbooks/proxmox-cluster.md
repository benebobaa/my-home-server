# Runbook: form the Proxmox cluster (`homelab`)

**When:** done once (2026-10-08) for pve2 + pve3; pve1 joins when built.
**Needs:** nodes converged (Ansible), same PVE version, the joining node's
root SSH key on the seed, corosync link IPs on VLAN 60 (`10.10.60.x`).

## 0. Values

| | seed (first node) | joining node(s) |
| --- | --- | --- |
| Node | pve3 | pve2 (pve1 later) |
| MGMT IP | 10.10.10.13 | 10.10.10.12 |
| Corosync link0 (VLAN 60) | 10.10.60.13 | 10.10.60.12 |
| Cluster name | `homelab` | — |

## 1. Prerequisites

- Ansible converged on all nodes (`ansible/proxmox-nodes.yml`).
- Same PVE version (run `--tags upgrade` where needed).
- The joining node can SSH to the seed as root (one-way is enough): install
  the joining node's `/root/.ssh/id_rsa.pub` into the seed's
  `authorized_keys`.
- Corosync IPs exist locally: `ip -br a | grep 10.10.60`.

## 2. Create (seed)

```bash
pvecm create homelab --link0 10.10.60.13
pvecm status          # 1 node, quorate
```

## 3. Join (each other node)

```bash
pvecm add 10.10.10.13 --use_ssh --link0 10.10.60.12 --force
```

PVE 9 gotchas, both handled by the flags above:

- **`--use_ssh`** — by default `pvecm add` uses the password-based API join
  and prompts for the seed's root password. `--use_ssh` selects the key-based
  flow (needs §1).
- **`--force`** — joining is refused if the node "already contains virtual
  guests" (protection against VM-ID collisions). Forcing skips the check,
  but note: **existing guest configs do NOT merge into the cluster — they
  are dropped from `/etc/pve`** (data volumes stay on storage; the join
  writes a pre-join database backup to
  `/var/lib/pve-cluster/backup/config-*.sql.gz`).
  - Preferred: stop + back up + remove guests before joining.
  - Or force (only when VM IDs do not collide!) and restore the configs from
    the backup. The 2026-10-08 pve2 join did exactly that for CT 100 (a
    temporary sandbox, removed the same day): the config was extracted from
    the dump and written back to `/etc/pve/nodes/<node>/lxc/<id>.conf`;
    volumes and snapshots were untouched.

## 4. Verify

```bash
pvecm status          # Quorate: Yes, expected votes = node count
pvecm nodes           # all nodes listed
corosync-cfgtool -s   # LINK ID 0 on the VLAN 60 address, connected
pvesh get /cluster/resources --type vm   # guests from all nodes
```

## Quorum notes

- 2-node cluster: if either node is down, quorum is lost (management actions
  lock; running guests keep running). Emergency: `pvecm expected 1` on the
  remaining node; reset with `pvecm expected 2` once both are back.
- pve1 joins as the 3rd node (same §3 command, `--link0 10.10.60.11`) — it is
  **on-demand (~4 days/week)** by design. Quorum is a majority, so a
  part-time member never hurts: while pve1 is up, any 2 of 3 nodes stay
  quorate (bonus: either laptop can be maintained); while pve1 is off, the
  two laptops must both be up (same as today). If you later want quorum that
  survives one laptop down while pve1 is off, add a corosync QDevice (e.g. on
  the future VPS).
