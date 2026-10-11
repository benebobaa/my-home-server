#!/usr/bin/env bash
# Kubeletto's platform on the home K3s cluster. Idempotent; run from the
# operator Mac (needs root SSH to pve2 and helm). The cluster API is not
# reachable from the LAN side (DMZ), so everything goes through the pinned root
# SSH to pve2 and the guest agent of VM 300 — whose stdin is capped at 1 MiB,
# hence the chunking. Secrets come first, from secrets.sh.
#
#   ./apply.sh            # everything below, in order
#   ./apply.sh <step>     # base | knative | traefik | platform | rehearsal
set -euo pipefail
cd "$(dirname "$0")"

NODE=root@10.10.10.12   # pve2 (inventory/lab.yaml: k3s on pve2)
VMID=300
KNATIVE_VERSION=1.16.0
KOURIER_VERSION=1.16.0
TRAEFIK_CHART_VERSION=40.2.0
CACHE="${TMPDIR:-/tmp}/kubeletto-home-cache"
mkdir -p "$CACHE"

# Run a bash script (stdin) inside the VM; print its output; fail on non-zero.
vm_bash() {
  ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout ${1:-300} -- bash -s" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
}

# Server-side apply multi-document YAML (stdin) in chunks under 900 KB.
kapply() {
  local dir; dir=$(mktemp -d)
  cat > "$dir/input"
  python3 - "$dir" <<'PY'
import sys, pathlib, re
out = pathlib.Path(sys.argv[1])
docs = [d for d in re.split(r"(?m)^---\s*$", (out / "input").read_text()) if d.strip(" \n#")]
chunk, size, n = [], 0, 0
def flush():
    global chunk, size, n
    if chunk:
        (out / f"{n:03d}.yaml").write_text("\n---\n".join(chunk)); n += 1
    chunk, size = [], 0
for d in docs:
    if size + len(d) > 900_000: flush()
    chunk.append(d); size += len(d)
flush()
PY
  for f in "$dir"/[0-9]*.yaml; do
    { echo 'k3s kubectl apply --server-side --force-conflicts --field-manager=homeserver -f - <<'"'"'KAPPLY_EOF'"'"''
      cat "$f"; echo; echo 'KAPPLY_EOF'; } | vm_bash 300 | grep -vE ' serverside-applied$| unchanged$' || true
  done
  rm -rf "$dir"
}

fetch() { # url -> cached file path
  local f
  f="$CACHE/$(basename "$1")-$2"
  [ -s "$f" ] || curl -fsSL "$1" -o "$f"
  echo "$f"
}

step_base() {
  echo "== base: namespaces + PriorityClass (Knative's patches reference it)"
  python3 -c 'import sys,yaml; sys.stdout.write("---\n".join(yaml.safe_dump(o, sort_keys=False) for o in yaml.safe_load_all(open("manifests/platform.yaml")) if o and o["kind"] in ("Namespace","PriorityClass")))' | kapply
}

step_knative() {
  echo "== Knative Serving $KNATIVE_VERSION + Kourier $KOURIER_VERSION (upstream)"
  kapply < "$(fetch https://github.com/knative/serving/releases/download/knative-v$KNATIVE_VERSION/serving-crds.yaml $KNATIVE_VERSION)"
  vm_bash <<<'k3s kubectl wait --for condition=established --timeout=60s crd/services.serving.knative.dev crd/revisions.serving.knative.dev >/dev/null'
  kapply < "$(fetch https://github.com/knative/serving/releases/download/knative-v$KNATIVE_VERSION/serving-core.yaml $KNATIVE_VERSION)"
  kapply < "$(fetch https://github.com/knative/net-kourier/releases/download/knative-v$KOURIER_VERSION/kourier.yaml $KOURIER_VERSION)"
  echo "== prod's Knative config + home placement"
  kapply < manifests/knative-config.yaml
  vm_bash 600 <<'EOF'
set -euo pipefail
k() { k3s kubectl "$@"; }
place='{"spec":{"template":{"spec":{"priorityClassName":"kubeletto-platform-critical","nodeSelector":{"node-role.kubernetes.io/control-plane":"true"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
for d in activator autoscaler controller webhook net-kourier-controller; do
  k -n knative-serving patch deployment "$d" --type merge -p "$place" >/dev/null
done
k -n kourier-system patch deployment 3scale-kourier-gateway --type merge -p "$place" >/dev/null
# prod's resource tweaks (Kubeletto scripts/setup-knative.sh)
k -n knative-serving patch deployment net-kourier-controller --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"50m"}]' >/dev/null
k -n kourier-system patch deployment 3scale-kourier-gateway --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"100m"}]' >/dev/null
# Kourier as ClusterIP (prod too): ServiceLB would open 80/443 on the DMZ nodes.
k -n kourier-system patch service kourier --type merge -p '{"spec":{"type":"ClusterIP","externalTrafficPolicy":null}}' >/dev/null
k -n knative-serving rollout status deploy --timeout=300s >/dev/null
k -n kourier-system rollout status deploy --timeout=300s >/dev/null
k get pods -n knative-serving -o wide --no-headers | awk '{print "  " $1, $3, $7}'
k get pods -n kourier-system -o wide --no-headers | awk '{print "  " $1, $3, $7}'
EOF
}

step_traefik() {
  echo "== Traefik (chart $TRAEFIK_CHART_VERSION, prod values + home changes)"
  helm repo list 2>/dev/null | grep -q '^traefik' || helm repo add traefik https://traefik.github.io/charts >/dev/null
  helm template traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" -n traefik \
    -f traefik-values.yaml --include-crds | kapply
}

step_platform() {
  echo "== platform: core, NATS, registry, Traefik routes, Redis"
  kapply < manifests/platform.yaml
  kapply < manifests/redis.yaml
  kapply < manifests/edge-policy.yaml
  vm_bash 600 <<'EOF'
set -euo pipefail
for ns in platform nats registry traefik; do
  k3s kubectl -n "$ns" rollout status deploy --timeout=300s >/dev/null || true
  k3s kubectl -n "$ns" get pods -o wide --no-headers | awk '{print "  " $1, $2, $3, $7}'
done
EOF
}

step_rehearsal() {
  echo "== rehearsal: operator allowlist, routes, probe Knative Service"
  # home-api serves a copy of production data with prod's JWT secret, so only
  # the operator may reach it: the operator LAN's IPv6 /64, detected now and
  # never committed (the repo is public). Not IPv4: tenant pods leave the
  # house through the same public IPv4 and would pass. The DMZ has no IPv6
  # and K3s pods are IPv4-only, so nothing in the cluster matches the /64.
  # depth 1 = the right-most X-Forwarded-For entry, the one Cloudflare
  # appends; Traefik trusts it only from the server node's pods.
  local v6 ranges
  v6=$(curl -s6 --max-time 5 https://api64.ipify.org || true)
  [[ $v6 == *:* ]] || { echo "no public IPv6 on this machine: home-api stays closed" >&2; exit 1; }
  ranges="\"$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]+"/64", strict=False))' "$v6")\""
  kapply <<ALLOW_EOF
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: home-api-allowlist
  namespace: traefik
spec:
  ipAllowList:
    sourceRange: [$ranges]
    ipStrategy: {depth: 1}
ALLOW_EOF
  kapply < manifests/rehearsal.yaml
}

case "${1:-all}" in
  base) step_base ;;
  knative) step_knative ;;
  traefik) step_traefik ;;
  platform) step_platform ;;
  rehearsal) step_rehearsal ;;
  all) step_base; step_knative; step_traefik; step_platform; step_rehearsal ;;
  *) echo "unknown step: $1" >&2; exit 2 ;;
esac
