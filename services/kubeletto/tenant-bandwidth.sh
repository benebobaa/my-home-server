#!/usr/bin/env bash
# Which tenant is using the network? Read-only. Samples the kubelet's per-pod
# network counters on every K3s node twice, <seconds> apart, adds the pods up
# per namespace, and names the tenant (slug and plan) for each Kubeletto
# namespace. Use it when WanQuotaPaceHigh, WanInboundDayHigh or
# TenantWorkerInboundSustained fires (docs/runbooks/alerts.md), and in the
# weekly review.
#
#   ./tenant-bandwidth.sh [seconds]     # default 60, 10-600
#
# Pods that live a minute or two (scale-to-zero apps) are partly missed between
# samples, and a pod that starts inside the window is counted from its start:
# read the numbers as a ranking, not an invoice. Host-network pods (the node
# exporter) report the node's own interface and are left out; the node's own
# total is the share's denominator. Pod-to-pod traffic on a node counts for the
# pods but never crosses the node's interface, so the shares can add up to
# more than 100 %: read the tenant rows, not the platform ones.
set -euo pipefail
cd "$(dirname "$0")"

NODE=root@10.10.10.12   # pve2 (inventory/lab.yaml: k3s on pve2)
VMID=300
SECS=${1:-60}
[[ $SECS =~ ^[0-9]+$ ]] && [ "$SECS" -ge 10 ] && [ "$SECS" -le 600 ] || { echo "seconds must be 10-600" >&2; exit 2; }

vm_bash() { # script on stdin; the remote timeout leaves room for the sampling gap
  ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout $((SECS + 120)) -- bash -s" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
}

# Remote half: two snapshots per node, aggregated per namespace, JSON out.
raw=$({ printf 'SECS=%s\n' "$SECS"; cat <<'REMOTE'
set -euo pipefail
command -v python3 >/dev/null || { echo "no python3 on the VM" >&2; exit 1; }
d=$(mktemp -d)
nodes=$(k3s kubectl get nodes -o name | cut -d/ -f2)
for n in $nodes; do k3s kubectl get --raw "/api/v1/nodes/$n/proxy/stats/summary" > "$d/$n.1"; done
sleep "$SECS"
for n in $nodes; do k3s kubectl get --raw "/api/v1/nodes/$n/proxy/stats/summary" > "$d/$n.2"; done
python3 - "$d" "$SECS" $nodes <<'PY'
import json, sys
d, secs, nodes = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
def net(o):
    n = (o or {}).get("network") or {}
    if "rxBytes" in n: return n["rxBytes"], n.get("txBytes", 0)
    ifs = n.get("interfaces") or []
    return sum(i.get("rxBytes", 0) for i in ifs), sum(i.get("txBytes", 0) for i in ifs)
ns_rx, ns_tx, node_rx, node_tx, pods_by_ns = {}, {}, 0, 0, {}
for n in nodes:
    a, b = json.load(open("%s/%s.1" % (d, n))), json.load(open("%s/%s.2" % (d, n)))
    r1, t1 = net(a["node"]); r2, t2 = net(b["node"])
    node_rx += max(r2 - r1, 0); node_tx += max(t2 - t1, 0)
    before = {p["podRef"]["uid"]: net(p) for p in a.get("pods", [])}
    for p in b.get("pods", []):
        ref = p["podRef"]; ns = ref["namespace"]
        if ns == "node-metrics": continue          # host network: reports the node's NIC
        rx2, tx2 = net(p)
        if ref["uid"] in before:
            rx1, tx1 = before[ref["uid"]]
            drx, dtx = max(rx2 - rx1, 0), max(tx2 - tx1, 0)
        else:
            drx, dtx = rx2, tx2                      # new pod: bytes since it started
        ns_rx[ns] = ns_rx.get(ns, 0) + drx; ns_tx[ns] = ns_tx.get(ns, 0) + dtx
        pods_by_ns[ns] = pods_by_ns.get(ns, 0) + 1
print(json.dumps({"secs": secs, "node_rx": node_rx, "node_tx": node_tx,
                  "ns": [{"ns": k, "rx": ns_rx[k], "tx": ns_tx.get(k, 0), "pods": pods_by_ns.get(k, 0)} for k in ns_rx]}))
PY
rm -rf "$d"
REMOTE
} | vm_bash)

# Local half: name the tenants (one read-only query) and print the table.
prefixes=$(printf '%s' "$raw" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
print(",".join(sorted({"\x27%s\x27" % m.group(1) for r in d["ns"] if (m := re.match(r"^kl-([0-9a-f]{8})-", r["ns"]))})))')
names=""
if [ -n "$prefixes" ]; then
  # Expanded here on purpose: $prefixes is only 8-hex-digit ids taken from the
  # namespace names by the regex above, so nothing else can reach the query.
  # shellcheck disable=SC2087
  names=$(ssh -o BatchMode=yes "$NODE" 'pct exec 130 -- su postgres -c "psql -d kubeletto -At -F \"|\" -f -"' 2>/dev/null <<SQL || true
select left(id::text, 8), slug, plan from tenants where left(id::text, 8) in ($prefixes);
SQL
  )
fi
printf '%s' "$raw" | NAMES="$names" python3 -c '
import json, os, re, sys
d = json.load(sys.stdin); secs = d["secs"]
who = {}
for line in os.environ.get("NAMES", "").splitlines():
    p = line.split("|")
    if len(p) == 3: who[p[0]] = (p[1], p[2])
def mbit(b): return b * 8 / secs / 1e6
print("window %ds, all nodes: node receives %.2f Mbit/s, sends %.2f Mbit/s" % (secs, mbit(d["node_rx"]), mbit(d["node_tx"])))
print("%9s %9s %6s %5s  %-24s %s" % ("rx Mbit/s", "tx Mbit/s", "share", "pods", "namespace", "tenant (plan)"))
for r in sorted(d["ns"], key=lambda r: -(r["rx"] + r["tx"]))[:12]:
    m = re.match(r"^kl-([0-9a-f]{8})-", r["ns"]); t = who.get(m.group(1)) if m else None
    share = "%3.0f%%" % (100 * r["rx"] / d["node_rx"]) if d["node_rx"] else "  -"
    print("%9.2f %9.2f %6s %5d  %-24s %s" % (mbit(r["rx"]), mbit(r["tx"]), share, r["pods"], r["ns"][:24],
          ("%s (%s)" % t) if t else ("" if m else "platform")))
'
