#!/usr/bin/env bash
# Root-only Proxmox firewall switches (run on a node by
# terraform_data.pve_firewall; the API token has no Sys.Modify).
#
# Why: the K3s VMs share VLAN 25 and run tenant code; their per-VM firewall
# (ipfilter/macfilter, proxmox/opentofu/firewall.tf) stops one claiming the
# other's address. Per-VM rules only act while the datacenter firewall is on
# — and the datacenter switch also turns on every HOST's firewall by default
# (host.fw `enable` defaults to 1), which would put the management path
# behind a DROP policy.
#
# So, in this order: host firewalls OFF on every node, then the datacenter ON
# with ACCEPT policies (belt and braces: even a host firewall switched on by
# mistake drops nothing). Containers are unaffected: their NICs have
# firewall=0. Idempotent.
#
# Rollback (either node): pvesh set /cluster/firewall/options --enable 0
set -euo pipefail

for node in $(pvesh get /nodes --output-format json | python3 -c 'import json,sys; print(" ".join(n["node"] for n in json.load(sys.stdin)))'); do
  pvesh set "/nodes/${node}/firewall/options" --enable 0
  echo "pve-firewall: host firewall on ${node}: off"
done

pvesh set /cluster/firewall/options --enable 1 --policy_in ACCEPT --policy_out ACCEPT --ebtables 1
echo "pve-firewall: datacenter firewall on (policy in/out ACCEPT, ebtables on)"

# Wait for pve-firewall to compile the rules on this node.
for _ in $(seq 1 30); do
  pve-firewall status | grep -q 'enabled/running' && break
  sleep 2
done
pve-firewall status
