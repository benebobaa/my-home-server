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
#   REDIS_URL -> its instance on the lab's shared Valkey (ADR 0016, TLS,
#     unverified: go-redis takes no CA from a URL); NATS_URL -> the in-cluster
#     NATS, a leaf of the lab's shared hub
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
# From proxmox/opentofu (ADR 0016): nats/nats-hub (url: the hub with account
# kubeletto's password), ConfigMap nats/nats-hub-ca (the hub's certificate,
# pinned by the leaf), and the Valkey instance's password in REDIS_URL.
# Mirrored into kubeletto-builds: ghcr-pull only (not core's internal secret).
#
# Where the prod-origin values come from (prod disappears on 2026-11-05):
#   ./secrets.sh snapshot          read prod once (read-only), write the keys
#                                  home keeps to secrets.prod-snapshot.sops.json
#                                  (SOPS, age; verified against prod, key names
#                                  and counts only). Aiven, Upstash and
#                                  OpenObserve values are NOT stored: home
#                                  replaces or drops them.
#   ./secrets.sh                   apply, prod-origin values read from prod
#   ./secrets.sh --from-snapshot   apply, read from the snapshot (after prod)
#   ./secrets.sh verify            compare the cluster's Secrets to the snapshot
#                                  by per-key hash (nothing printed but names)
#   --live                         cutover: keep RESEND_API_KEY and SUMOPOD_*
#                                  (mail, checkout); the rehearsal drops them
# The snapshot file is gitignored on purpose: it is the ciphertext of every
# shared prod secret, and this repo is public. Committing it is the
# operator's call (docs/runbooks/kubeletto-migration.md, "Secrets").
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(git rev-parse --show-toplevel)

PROD=${KUBELETTO_PROD_SSH:-root@103.59.160.198}
NODE=root@10.10.10.12
VMID=300
SNAPSHOT=secrets.prod-snapshot.sops.json

MODE=apply SOURCE=prod LIVE=0
for a in "$@"; do
  case "$a" in
    snapshot|verify) MODE=$a ;;
    --from-snapshot) SOURCE=snapshot ;;
    --live) LIVE=1 ;;
    *) echo "usage: $0 [snapshot|verify] [--from-snapshot] [--live]" >&2; exit 2 ;;
  esac
done
export LIVE

PROD_SECRETS="platform/platform-core-env platform/ghcr-pull platform/platform-core-internal-auth
platform/platform-core-registry-pull registry/registry-http-secret registry/registry-r2-credentials
traefik/kubeletto-app-tls traefik/kubeletto-com-tls traefik/platform-team-basic-auth"

vm() {
  ssh -o BatchMode=yes "$NODE" "qm guest exec $VMID --pass-stdin 1 --timeout ${1:-120} -- bash -s" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data","")); sys.exit(d.get("exitcode",1))'
}

# Keys of platform-core-env that home sets itself: never read from prod's
# values, never stored in the snapshot (Aiven, Upstash, prod's NATS and the
# rented server's addresses are not needed after the move).
export HOME_OVERRIDE_KEYS="DATABASE_URL,DATABASE_URL_DIRECT,REDIS_URL,NATS_URL,NATS_USER,NATS_PASSWORD,NATS_BUILD_USER,TENANT_EGRESS_DENY_CIDRS,DOMAINS_EDGE_IPS,DOMAINS_PROBE_ADDR,PLATFORM_API_URL,SESSION_COOKIE_DOMAIN,CLOUDFLARE_SAAS_TOKEN"

remote="echo '{\"kind\":\"List\",\"apiVersion\":\"v1\",\"items\":['; sep=''; for s in $(tr '\n' ' ' <<<"$PROD_SECRETS"); do printf '%s' \"\$sep\"; kubectl -n \${s%%/*} get secret \${s#*/} -o json; sep=','; done; echo ']}'"

# A kubectl-style List of the prod-origin Secrets, from prod or the snapshot.
prod_items() {
  if [ "$SOURCE" = snapshot ]; then
    [ -f "$SNAPSHOT" ] || { echo "secrets: no $SNAPSHOT (run: $0 snapshot)" >&2; exit 1; }
    sops decrypt "$SNAPSHOT"
  else
    ssh -o BatchMode=yes "$PROD" "$remote" 2>/dev/null
  fi
}

# Compare the snapshot with another List on stdin, value by value; prints key
# names only. RESEND/SUMOPOD are skipped unless --live: the rehearsal drops them.
compare_with_snapshot() {
  SNAP_JSON=$(sops decrypt "$SNAPSHOT") python3 -c '
import json, os, sys
snap = json.loads(os.environ["SNAP_JSON"])["items"]
other = {(s["metadata"]["namespace"], s["metadata"]["name"]): s.get("data", {}) for s in json.load(sys.stdin)["items"]}
live = os.environ.get("LIVE") == "1"
skip = lambda k: not live and (k == "RESEND_API_KEY" or k.startswith("SUMOPOD_"))
n = bad = 0
for s in snap:
    key = (s["metadata"]["namespace"], s["metadata"]["name"])
    cur = other.get(key)
    if cur is None:
        print("MISSING %s/%s" % key); bad += 1; continue
    for k, v in s["data"].items():
        if skip(k): continue
        n += 1
        if cur.get(k) != v:
            print("DIFF %s/%s %s" % (key + (k,))); bad += 1
print("%d values compared across %d secrets, %d differ" % (n, len(snap), bad))
sys.exit(1 if bad else 0)'
}

if [ "$MODE" = snapshot ]; then
  prod_items | python3 -c '
import json, os, sys
over = set(os.environ["HOME_OVERRIDE_KEYS"].split(","))
items = []
for s in json.load(sys.stdin)["items"]:
    data = dict(s.get("data", {}))
    if s["metadata"]["name"] == "platform-core-env":
        data = {k: v for k, v in data.items() if k not in over and not k.startswith(("OPENOBSERVE_", "OTEL_"))}
    items.append({"metadata": {"namespace": s["metadata"]["namespace"], "name": s["metadata"]["name"]},
                  "type": s.get("type", "Opaque"), "data": data})
    print("%s/%s: %d keys" % (s["metadata"]["namespace"], s["metadata"]["name"], len(data)), file=sys.stderr)
json.dump({"items": items}, sys.stdout)' |
    sops encrypt --input-type json --output-type json --filename-override "$SNAPSHOT" /dev/stdin > "$SNAPSHOT.tmp"
  mv "$SNAPSHOT.tmp" "$SNAPSHOT"
  echo "== verify the snapshot against prod (read again)" >&2
  SOURCE=prod prod_items | LIVE=1 compare_with_snapshot
  exit 0
fi

if [ "$MODE" = verify ]; then
  # The same Secrets, read from the home cluster (a missing one shows as MISSING).
  # shellcheck disable=SC2016 # the printf strings are a script for the VM
  {
    printf 'echo "{\\"kind\\":\\"List\\",\\"apiVersion\\":\\"v1\\",\\"items\\":["; sep=""\n'
    printf 'for s in %s; do\n' "$(tr '\n' ' ' <<<"$PROD_SECRETS")"
    printf '  printf "%%s" "$sep"; sep=","\n'
    printf '  k3s kubectl -n "${s%%%%/*}" get secret "${s#*/}" -o json 2>/dev/null || printf "{\\"metadata\\":{\\"namespace\\":\\"x\\",\\"name\\":\\"x\\"},\\"data\\":{}}"\n'
    printf 'done\necho "]}"\n'
  } | vm 120 | compare_with_snapshot
  exit 0
fi

HOME_PG_PASSWORD=$(cd "$REPO/proxmox/opentofu" &&
  echo 'nonsensitive(random_password.postgres["kubeletto"].result)' |
  sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tr -d '"')
[ ${#HOME_PG_PASSWORD} -ge 20 ] || { echo "secrets: no kubeletto DB password from tofu" >&2; exit 1; }
HOME_PG_HOST=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["hosts"]["postgres"]["ip"])' "$REPO/inventory/lab.yaml")
# The shared NATS hub and Valkey (ADR 0016): passwords from the state, the
# hub's certificate from its output, addresses from lab.yaml (the DMZ does not
# resolve home.arpa).
tf() { (cd "$REPO/proxmox/opentofu" && echo "$1" | sops exec-env secrets.sops.env 'tofu console' 2>/dev/null | tr -d '"'); }
HUB_PASSWORD=$(tf 'nonsensitive(random_password.nats["kubeletto"].result)')
VALKEY_PASSWORD=$(tf 'nonsensitive(random_password.valkey["kubeletto"].result)')
[ ${#HUB_PASSWORD} -ge 20 ] && [ ${#VALKEY_PASSWORD} -ge 20 ] || { echo "secrets: no NATS/Valkey password from tofu" >&2; exit 1; }
HUB_CA=$(cd "$REPO/proxmox/opentofu" && sops exec-env secrets.sops.env 'tofu output -raw nats_tls_cert')
[[ $HUB_CA == *"BEGIN CERTIFICATE"* ]] || { echo "secrets: no nats_tls_cert output" >&2; exit 1; }
HUB_HOST=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["hosts"]["nats"]["ip"])' "$REPO/inventory/lab.yaml")
VALKEY_HOST=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["hosts"]["valkey"]["ip"])' "$REPO/inventory/lab.yaml")
VALKEY_PORT=6380   # local.valkey_instances.kubeletto.port in proxmox/opentofu/valkey.tf
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
export HUB_PASSWORD VALKEY_PASSWORD HUB_CA HUB_HOST VALKEY_HOST VALKEY_PORT

prod_items | python3 -c '
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
# How the leaf reaches the hub. The URL is env-substituted whole into nats.conf
# (a tls:// string parses safely whatever the password starts with; tested).
out.append(secret("nats", "nats-hub", {"url": b64("tls://kubeletto:%s@%s:7422" % (
    u.quote(os.environ["HUB_PASSWORD"], safe=""), os.environ["HUB_HOST"]))}))
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
    "REDIS_URL": b64("rediss://:%s@%s:%s/0?skip_verify=true" % (
        u.quote(os.environ["VALKEY_PASSWORD"], safe=""), os.environ["VALKEY_HOST"], os.environ["VALKEY_PORT"])),
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
live = os.environ.get("LIVE") == "1"
dropped = sorted(k for k in env if (not live and (k == "RESEND_API_KEY" or k.startswith("SUMOPOD_"))) or k.startswith(("OPENOBSERVE_", "OTEL_")))
for k in dropped:
    del env[k]
print("platform-core-env: %d keys, dropped %s" % (len(env), ",".join(dropped)), file=sys.stderr)
for s in out:
    print("%s/%s: %s" % (s["metadata"]["namespace"], s["metadata"]["name"], ",".join(sorted(s["data"]))), file=sys.stderr)
for ns in sorted({s["metadata"]["namespace"] for s in out}):
    print("k3s kubectl create namespace %s --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null" % ns)
print("k3s kubectl -n kubeletto-builds delete secret platform-core-internal-auth --ignore-not-found >/dev/null")
ca = {"apiVersion": "v1", "kind": "ConfigMap",
      "metadata": {"name": "nats-hub-ca", "namespace": "nats",
                   "labels": {"app.kubernetes.io/managed-by": "homeserver-repo"}},
      "data": {"ca.pem": os.environ["HUB_CA"].rstrip("\n") + "\n"}}
print("k3s kubectl apply -f - <<'"'"'SECRETS_EOF'"'"'")
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": out + [ca]}))
print("SECRETS_EOF")
' | vm 120
