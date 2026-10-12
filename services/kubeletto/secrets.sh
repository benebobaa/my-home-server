#!/usr/bin/env bash
# Kubeletto's Secrets on the home cluster, for the home overlay
# (Kubeletto repo infra/k8s/home). Shared credentials are piped from
# production (read with `kubectl get secret -o json` on the prod host); home
# credentials are generated here, or reused when the cluster already has
# them. Everything is rewritten in memory and applied in VM 300 through the
# guest agent's stdin: nothing lands on disk or in argv, and only names and
# key lists are printed.
#
# platform-core-env, from prod with:
#   DATABASE_URL, DATABASE_URL_DIRECT -> the home database in CT 130
#   REDIS_URL -> in-cluster Valkey; NATS_URL -> home NATS by DNS
#   NATS_USER/NATS_PASSWORD (platform) + NATS_BUILD_USER (wave 2 NATS auth)
#   TENANT_EGRESS_DENY_CIDRS -> CGNAT + the home public IPv4 (not in git)
#   DOMAINS_EDGE_IPS -> Cloudflare's addresses for kubeletto.app;
#   DOMAINS_PROBE_ADDR -> the in-cluster Traefik (platform-subdomain probes)
#   + CLOUDFLARE_SAAS_TOKEN from secrets.sops.env (this directory): core's
#     own token for custom domains as Cloudflare for SaaS custom hostnames
#     (decision D4; SSL and Certificates on kubeletto.app only)
#   PLATFORM_API_URL, SESSION_COOKIE_DOMAIN -> no longer the rented server's IP
#   dropped: RESEND_API_KEY, SUMOPOD_* (rehearsal), OPENOBSERVE_*, OTEL_*
# JWT_SECRET, GITHUB_*, R2_*, INFISICAL_*, REGISTRY_AUTH_PRIVATE_KEY stay
# prod's: shared services, and JWT_SECRET derives the GitHub token keys.
#
# Generated at home: nats/nats-auth (platform/vector/build passwords),
# logs/vector-nats-auth, kubeletto-builds/build-nats-auth.
# Mirrored into kubeletto-builds: ghcr-pull only (not core's internal secret).
#
# At cutover this becomes a SOPS file in this repo (app standard §4).
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(git rev-parse --show-toplevel)

PROD=root@103.59.160.198
NODE=root@10.10.10.12
VMID=300

PROD_SECRETS="platform/platform-core-env platform/ghcr-pull platform/platform-core-internal-auth
platform/platform-core-registry-pull registry/registry-http-secret registry/registry-r2-credentials
traefik/kubeletto-app-tls traefik/kubeletto-com-tls traefik/platform-team-basic-auth"

vm() {
  ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout ${1:-120} -- bash -s" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
}

HOME_PG_PASSWORD=$(cd "$REPO/proxmox/opentofu" &&
  echo 'nonsensitive(random_password.postgres["kubeletto"].result)' |
  sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tr -d '"')
[ ${#HOME_PG_PASSWORD} -ge 20 ] || { echo "secrets: no kubeletto DB password from tofu" >&2; exit 1; }
HOME_PG_HOST=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["hosts"]["postgres"]["ip"])' "$REPO/inventory/lab.yaml")
HOME_IPV4=$(ssh -o BatchMode=yes "$NODE" 'curl -s4 --max-time 5 https://api.ipify.org')
[[ $HOME_IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "secrets: no home public IPv4" >&2; exit 1; }
EDGE_IPS=$(dig +short probe-rehearsal.kubeletto.app A | grep -E '^[0-9.]+$' | sort | paste -sd, -)
[ -n "$EDGE_IPS" ] || { echo "secrets: no Cloudflare edge IPs" >&2; exit 1; }
# shellcheck disable=SC2016 # expanded by the shell sops starts, not here
CLOUDFLARE_SAAS_TOKEN=$(sops exec-env secrets.sops.env 'printf %s "$CLOUDFLARE_SAAS_TOKEN"')
[ ${#CLOUDFLARE_SAAS_TOKEN} -ge 40 ] || { echo "secrets: no CLOUDFLARE_SAAS_TOKEN in secrets.sops.env" >&2; exit 1; }
# Existing home NATS passwords, so a re-run never rotates them under running pods.
EXISTING_NATS=$(echo 'k3s kubectl -n nats get secret nats-auth -o json 2>/dev/null || echo "{}"' | vm)
export HOME_PG_PASSWORD HOME_PG_HOST HOME_IPV4 EDGE_IPS EXISTING_NATS CLOUDFLARE_SAAS_TOKEN

remote="echo '{\"kind\":\"List\",\"apiVersion\":\"v1\",\"items\":['; sep=''; for s in $(tr '\n' ' ' <<<"$PROD_SECRETS"); do printf '%s' \"\$sep\"; kubectl -n \${s%%/*} get secret \${s#*/} -o json; sep=','; done; echo ']}'"

ssh -o BatchMode=yes "$PROD" "$remote" 2>/dev/null | python3 -c '
import base64, json, os, secrets, sys, urllib.parse as u
b64 = lambda s: base64.b64encode(s.encode()).decode()
prod = {(s["metadata"]["namespace"], s["metadata"]["name"]): s for s in json.load(sys.stdin)["items"]}
def secret(ns, name, data, typ="Opaque"):
    return {"apiVersion": "v1", "kind": "Secret", "type": typ,
            "metadata": {"name": name, "namespace": ns,
                         "labels": {"app.kubernetes.io/managed-by": "homeserver-repo"}},
            "data": data}
out = []
for (ns, name), s in prod.items():
    out.append(secret(ns, name, dict(s.get("data", {})), s.get("type", "Opaque")))

# NATS parses an env-substituted password like a config token: urlsafe
# characters ("-" first, digits) can be misread, so passwords are a letter
# plus hex. Older-format values are regenerated.
import re
old = json.loads(os.environ["EXISTING_NATS"] or "{}").get("data", {})
def keep(v):
    return v if v and re.fullmatch(r"k[0-9a-f]{48}", base64.b64decode(v).decode()) else None
nats = {k: keep(old.get(k)) or b64("k" + secrets.token_hex(24))
        for k in ("platform-password", "vector-password", "build-password")}
out.append(secret("nats", "nats-auth", nats))
out.append(secret("logs", "vector-nats-auth", {"password": nats["vector-password"]}))
out.append(secret("kubeletto-builds", "build-nats-auth", {"password": nats["build-password"]}))
# Build pods run untrusted Dockerfile steps: they get the image-pull secret
# only. The platform-wide INTERNAL_AUTH_SECRET of core is NOT mirrored; builds
# authenticate with per-build tokens (BUILD_LEGACY_INTERNAL_AUTH=false, wave 2).
s = prod[("platform", "ghcr-pull")]
out.append(secret("kubeletto-builds", "ghcr-pull", dict(s["data"]), s.get("type", "Opaque")))

env = next(s for s in out if s["metadata"]["name"] == "platform-core-env")["data"]
dsn = "postgresql://kubeletto:%s@%s:5432/kubeletto?sslmode=require" % (
    u.quote(os.environ["HOME_PG_PASSWORD"], safe=""), os.environ["HOME_PG_HOST"])
env.update({
    "DATABASE_URL": b64(dsn), "DATABASE_URL_DIRECT": b64(dsn),
    "REDIS_URL": b64("redis://valkey.platform.svc.cluster.local:6379"),
    "NATS_URL": b64("nats://nats.nats.svc.cluster.local:4222"),
    "NATS_USER": b64("platform"), "NATS_PASSWORD": nats["platform-password"],
    "NATS_BUILD_USER": b64("build"),
    "TENANT_EGRESS_DENY_CIDRS": b64("100.64.0.0/10,%s/32" % os.environ["HOME_IPV4"]),
    "DOMAINS_EDGE_IPS": b64(os.environ["EDGE_IPS"]),
    "DOMAINS_PROBE_ADDR": b64("traefik.traefik.svc.cluster.local:443"),
    "PLATFORM_API_URL": b64("https://api.kubeletto.com"),
    "SESSION_COOKIE_DOMAIN": b64("api.kubeletto.com"),
    "CLOUDFLARE_SAAS_TOKEN": b64(os.environ["CLOUDFLARE_SAAS_TOKEN"]),
})
dropped = sorted(k for k in env if k == "RESEND_API_KEY" or k.startswith(("SUMOPOD_", "OPENOBSERVE_", "OTEL_")))
for k in dropped:
    del env[k]
print("platform-core-env: %d keys, dropped %s" % (len(env), ",".join(dropped)), file=sys.stderr)
for s in out:
    print("%s/%s: %s" % (s["metadata"]["namespace"], s["metadata"]["name"], ",".join(sorted(s["data"]))), file=sys.stderr)
for ns in sorted({s["metadata"]["namespace"] for s in out}):
    print("k3s kubectl create namespace %s --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null" % ns)
print("k3s kubectl -n kubeletto-builds delete secret platform-core-internal-auth --ignore-not-found >/dev/null")
print("k3s kubectl apply -f - <<'"'"'SECRETS_EOF'"'"'")
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": out}))
print("SECRETS_EOF")
' | vm 120
