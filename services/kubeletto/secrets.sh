#!/usr/bin/env bash
# Kubeletto's Secrets for the home cluster, piped from production: read with
# `kubectl get secret -o json` on the prod host, rewritten in memory, applied in
# VM 300 through the guest agent's stdin. Nothing lands on disk or in argv, and
# only names and key lists are printed.
#
# Rehearsal rewrite of platform-core-env (runbook kubeletto-migration.md):
#   DATABASE_URL, DATABASE_URL_DIRECT -> the home copy in CT 130 (its password
#     from proxmox/opentofu, random_password.postgres["kubeletto"])
#   REDIS_URL -> the in-cluster Redis (manifests/redis.yaml)
#   NATS_URL -> the home NATS by DNS (prod's value is its own ClusterIP)
# Still prod's at cutover, to change then: PLATFORM_API_URL and
# SESSION_COOKIE_DOMAIN carry the rented server's public IP.
#   dropped: RESEND_API_KEY (mail), SUMOPOD_* (payments), OPENOBSERVE_*, OTEL_*
# Everything else is prod's value: JWT_SECRET must match (it derives the
# per-user GitHub token keys), and R2/GitHub/Infisical are the shared services.
#
# At cutover this becomes a SOPS file in this repo (app standard §4).
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(git rev-parse --show-toplevel)

PROD=root@103.59.160.198
NODE=root@10.10.10.12
VMID=300

SECRETS="platform/platform-core-env platform/ghcr-pull platform/platform-core-internal-auth
platform/platform-core-registry-pull registry/registry-auth-public-key registry/registry-http-secret
registry/registry-r2-credentials traefik/kubeletto-app-tls traefik/kubeletto-com-tls
traefik/platform-team-basic-auth"

HOME_PG_PASSWORD=$(cd "$REPO/proxmox/opentofu" &&
  echo 'nonsensitive(random_password.postgres["kubeletto"].result)' |
  sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tr -d '"')
[ ${#HOME_PG_PASSWORD} -ge 20 ] || { echo "secrets: no kubeletto DB password from tofu" >&2; exit 1; }
HOME_PG_HOST=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["hosts"]["postgres"]["ip"])' "$REPO/inventory/lab.yaml")
export HOME_PG_PASSWORD HOME_PG_HOST

remote="echo '{\"kind\":\"List\",\"apiVersion\":\"v1\",\"items\":['; sep=''; for s in $(tr '\n' ' ' <<<"$SECRETS"); do printf '%s' \"\$sep\"; kubectl -n \${s%%/*} get secret \${s#*/} -o json; sep=','; done; echo ']}'"

ssh -o BatchMode=yes "$PROD" "$remote" 2>/dev/null | python3 -c '
import base64, json, os, sys, urllib.parse as u
lst = json.load(sys.stdin)
b64 = lambda s: base64.b64encode(s.encode()).decode()
for s in lst["items"]:
    m = s["metadata"]
    s["metadata"] = {"name": m["name"], "namespace": m["namespace"],
                     "labels": {"app.kubernetes.io/managed-by": "homeserver-repo"}}
    if m["name"] == "platform-core-env":
        d = s["data"]
        dsn = "postgresql://kubeletto:%s@%s:5432/kubeletto?sslmode=require" % (
            u.quote(os.environ["HOME_PG_PASSWORD"], safe=""), os.environ["HOME_PG_HOST"])
        d["DATABASE_URL"] = d["DATABASE_URL_DIRECT"] = b64(dsn)
        d["REDIS_URL"] = b64("redis://redis.platform.svc.cluster.local:6379")
        # prod pins NATS by its ClusterIP (10.43.196.254), which is nothing here
        d["NATS_URL"] = b64("nats://nats.nats.svc.cluster.local:4222")
        dropped = sorted(k for k in d if k == "RESEND_API_KEY" or k.startswith(("SUMOPOD_", "OPENOBSERVE_", "OTEL_")))
        for k in dropped: del d[k]
        print("platform-core-env: %d keys, dropped %s" % (len(d), ",".join(dropped)), file=sys.stderr)
    print("%s/%s: %s" % (m["namespace"], m["name"], ",".join(sorted(s.get("data", {})))), file=sys.stderr)
for ns in sorted({s["metadata"]["namespace"] for s in lst["items"]}):
    print("k3s kubectl create namespace %s --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null" % ns)
print("k3s kubectl apply -f - <<'"'"'SECRETS_EOF'"'"'")
print(json.dumps(lst))
print("SECRETS_EOF")
' | ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout 120 -- bash -s" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
