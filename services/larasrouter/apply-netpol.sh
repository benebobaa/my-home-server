#!/usr/bin/env bash
# Apply larasrouter's additive egress policy to its tenant namespace through
# the K3s server VM's guest agent (the cluster API is not reachable from the LAN).
set -euo pipefail
cd "$(dirname "$0")"
NODE=root@10.10.10.12 VMID=300
ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout 60 -- /usr/local/bin/k3s kubectl apply -f -" < tenant-netpol.yaml |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
