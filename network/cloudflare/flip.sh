#!/usr/bin/env bash
# The Kubeletto DNS flip (docs/runbooks/kubeletto-cutover.md step 9) and its
# rollback, without a gap.
#
# Why not `tofu apply` alone: changing a record's type (A -> CNAME) makes the
# provider REPLACE it (destroy, then create). For *.kubeletto.app that is a gap of
# a second or two with no record, and a resolver that asks during it can cache
# "does not exist". Cloudflare's API changes the type IN PLACE (same record id,
# tested 2026-10-14 on a throwaway record), so this script PATCHes the three
# records, then `tofu plan` must say "No changes" because the real records now
# match the code on the `cutover-flip` branch.
#
#   ./flip.sh forward            dry run: current values and what would be set
#   ./flip.sh forward --apply    *.kubeletto.app and api.kubeletto.com -> the
#                                tunnel; domains.kubeletto.app -> saas-origin
#   ./flip.sh back [--apply]     the three records back to the rented server
#
# Order on the night: `git switch cutover-flip` BEFORE forward (the code is the
# "after"), `./flip.sh forward --apply`, then `sops exec-env secrets.sops.env
# 'tofu plan'` must show No changes. Rollback: `./flip.sh back --apply`, then
# `git switch main` and the same plan check. Merge the branch only after the
# rollback window is over.
set -euo pipefail
cd "$(dirname "$0")"

DIR=${1:-}; APPLY=${2:-}
[[ $DIR =~ ^(forward|back)$ ]] && [[ -z $APPLY || $APPLY = --apply ]] || { sed -n 2,24p "$0" >&2; exit 2; }
[ "$DIR" = back ] && { echo "refusing: the rented server was wiped on 2026-10-28, the rollback is over" >&2; exit 1; }

PROD_IP=103.59.160.198
ACCOUNT=f650e5eb59b56b70048a841520541189   # not secret (tunnel.tf)
TUNNEL_NAME=kubeletto-home
API=https://api.cloudflare.com/client/v4

export DIR APPLY PROD_IP ACCOUNT TUNNEL_NAME API
exec sops exec-env secrets.sops.env 'python3 - <<"PY"
import json, os, sys, urllib.request, urllib.parse

H = {"Authorization": "Bearer " + os.environ["CLOUDFLARE_API_TOKEN"], "Content-Type": "application/json"}
API, ACCOUNT, PROD = os.environ["API"], os.environ["ACCOUNT"], os.environ["PROD_IP"]
forward, apply_ = os.environ["DIR"] == "forward", os.environ["APPLY"] == "--apply"

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, headers=H, data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
    if not d.get("success"):
        sys.exit("API error on %s %s: %s" % (method, path, d.get("errors")))
    return d["result"]

tun = call("GET", "/accounts/%s/cfd_tunnel?name=%s&is_deleted=false" % (ACCOUNT, os.environ["TUNNEL_NAME"]))
if len(tun) != 1:
    sys.exit("expected exactly one tunnel named %s, found %d" % (os.environ["TUNNEL_NAME"], len(tun)))
tunnel_target = tun[0]["id"] + ".cfargotunnel.com"

# name, zone, (type, content, proxied) after the flip, and before it
plan = [
    ("*.kubeletto.app", "kubeletto.app", ("CNAME", tunnel_target, True), ("A", PROD, True)),
    ("api.kubeletto.com", "kubeletto.com", ("CNAME", tunnel_target, True), ("A", PROD, True)),
    ("domains.kubeletto.app", "kubeletto.app", ("CNAME", "saas-origin.kubeletto.app", True), ("A", PROD, False)),
]
zones = {}
def zone(n):
    if n not in zones:
        r = call("GET", "/zones?name=" + n)
        if not r: sys.exit("no access to zone " + n)
        zones[n] = r[0]["id"]
    return zones[n]

todo = []
for name, zn, after, before in plan:
    want = after if forward else before
    recs = [r for r in call("GET", "/zones/%s/dns_records?name=%s" % (zone(zn), urllib.parse.quote(name))) if r["type"] in ("A", "AAAA", "CNAME")]
    if len(recs) != 1:
        sys.exit("%s: expected exactly one A/AAAA/CNAME record, found %d: stop, look at it by hand" % (name, len(recs)))
    r = recs[0]
    have = (r["type"], r["content"], bool(r["proxied"]))
    state = "already there" if have == want else "will change"
    print("%-24s now %-6s %-58s proxied=%-5s -> %-6s %-58s proxied=%-5s  [%s]" % (name, have[0], have[1], have[2], want[0], want[1], want[2], state))
    if have != want:
        todo.append((name, zn, r["id"], want, have))

if not apply_:
    print("dry run: nothing changed (pass --apply)")
    sys.exit(0)
for name, zn, rid, want, have in todo:
    call("PATCH", "/zones/%s/dns_records/%s" % (zone(zn), rid), {"type": want[0], "content": want[1], "proxied": want[2]})
    got = call("GET", "/zones/%s/dns_records/%s" % (zone(zn), rid))
    ok = (got["type"], got["content"], bool(got["proxied"])) == want
    print("%-24s patched in place (id %s…): %s" % (name, rid[:8], "verified" if ok else "MISMATCH"))
    if not ok:
        sys.exit("verification failed for " + name)
print("done: %d record(s) changed. Next: tofu plan must show No changes." % len(todo))
PY'
