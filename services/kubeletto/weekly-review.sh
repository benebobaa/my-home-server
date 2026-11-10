#!/usr/bin/env bash
# The weekly 15-minute review of Kubeletto tenants (operating model D19, D23):
# one read-only report of who looks abusive, broken or expensive, so the
# decision to pause or contact someone is made from numbers, not from hunches.
# Nothing here changes anything; pausing a service is the operator's call.
#
#   ./weekly-review.sh            # about a minute (a 30 s network sample)
#   NET_SECS=0 ./weekly-review.sh # skip the network sample
#
# Sections (each says where its number comes from):
#   1. Network: who uses the line right now (tenant-bandwidth.sh)
#   2. Cold-start churn: tenant apps that start more than 200 pods a day
#   3. Crash loops: tenant containers restarting more than 50 times a day
#   4. Traffic: top services by requests over 7 days, with their error share
#   5. Always-on: tenants whose app never scales to zero, with their request counts
#   6. Accounts: tenants by plan, how many are paused, how many are new
#   7. Funnel: signups and activation by week, checkouts, renewals, abuse
#      suspensions (the baseline for the 2026-12-07 trial-enforcement read, D31)
# Tenants appear by slug and plan, never by name or e-mail.
set -euo pipefail
cd "$(dirname "$0")"

PROM=${PROM_URL:-http://10.10.10.16:9090}   # the lab's Prometheus (CT 120)
NODE=root@10.10.10.12                        # pve2: the Kubeletto database is CT 130 there
NET_SECS=${NET_SECS:-30}

prom() { curl -s -m 30 "$PROM/api/v1/query" --data-urlencode "query=$1"; }
db() { # SQL on stdin, '|'-separated rows out
  ssh -o BatchMode=yes "$NODE" 'pct exec 130 -- su postgres -c "psql -d kubeletto -At -F \"|\" -f -"'
}

churn=$(prom 'count by (namespace) (last_over_time(kube_pod_info{job="service_dmz", namespace=~"kl-.*"}[1d]))')
loops=$(prom 'sum by (namespace) (increase(kube_pod_container_status_restarts_total{job="service_dmz", namespace=~"kl-.*", container="user-container"}[1d]))')

traffic_and_accounts=$(db <<'SQL'
select 'traffic', left(t.id::text, 8), t.slug, t.plan, sum(s.value)::bigint,
       coalesce(round(100.0 * sum(coalesce((s.metadata->>'request_4xx_count')::int, 0) + coalesce((s.metadata->>'request_5xx_count')::int, 0)) / nullif(sum(s.value), 0), 1), 0)
from usage_samples s join tenants t on t.id = s.tenant_id
where s.metric = 'http_requests' and s.sampled_at > now() - interval '7 days'
group by 2, 3, 4 order by 5 desc limit 5;
-- 'burn': average RESERVED CPU over 7 days (millicores): pod uptime times the
-- CPU limit, from runtime_vcpu_seconds, not CPU actually used (these pods use
-- 0.001 to 0.03 core). About 500 means the pod of a free app was up all week, i.e.
-- it never scaled to zero. Proxy/tunnel templates (Nezha, Xray) do that with
-- almost no traffic. It is a lead, not proof: the 2026-11-10 suspensions were
-- decided by looking inside the pods (agent processes, obfuscated entrypoints).
select 'burn', left(t.id::text, 8), t.slug, t.plan,
       round(1000 * u.vcpu / 604800)::bigint, u.reqs::bigint
from (select tenant_id,
             coalesce(sum(value) filter (where metric = 'runtime_vcpu_seconds'), 0) vcpu,
             coalesce(sum(value) filter (where metric = 'http_requests'), 0) reqs
      from usage_samples where sampled_at > now() - interval '7 days' group by 1) u
join tenants t on t.id = u.tenant_id
where t.suspended_at is null and t.plan <> 'internal' and u.vcpu / 604800 >= 0.25
order by u.vcpu desc limit 12;
select 'plan', plan, count(*), count(*) filter (where suspended_at is not null),
       count(*) filter (where created_at > now() - interval '7 days'), 0 from tenants group by plan order by plan;
select 'slug', left(id::text, 8), slug, plan, 0, 0 from tenants;
-- Funnel (D31). Signups by week: all tenants but the platform own ones; abuse
-- counts those suspended for abuse; activated means a deployment that went
-- active within 7 days of signup (failed deployments do not count).
select 'fwk', to_char(date_trunc('week', t.created_at), 'YYYY-MM-DD'), count(*),
       count(*) filter (where t.suspension_reason like 'abuse%'),
       count(*) filter (where exists (select 1 from deployments d where d.tenant_id = t.id
                         and d.status = 'active' and d.created_at < t.created_at + interval '7 days')), 0
from tenants t where t.plan <> 'internal' and t.created_at > now() - interval '5 weeks' group by 2 order by 2;
-- Checkouts started in the last 30 days, by outcome (production payments only).
select 'fpay', status, count(*), count(distinct tenant_id), 0, 0
from payments where created_at > now() - interval '30 days' and provider_env = 'production' group by status order by status;
-- Paying now, due to renew within 14 days, and repeat payers (two or more completed payments).
select 'frenew', 'paying_now', count(*), 0, 0, 0
from tenant_plan_assignments a join plans p on p.id = a.plan_id
where a.status = 'active' and p.monthly_price_idr > 0 and a.current_period_end > now();
select 'frenew', 'due_14d', count(*), 0, 0, 0
from tenant_plan_assignments a join plans p on p.id = a.plan_id
where a.status = 'active' and p.monthly_price_idr > 0 and a.current_period_end between now() and now() + interval '14 days';
select 'frenew', 'repeat_payers', count(*), 0, 0, 0
from (select tenant_id from payments where status = 'completed' and provider_env = 'production'
      group by tenant_id having count(*) >= 2) r;
select 'frenew', 'ever_paid', count(distinct tenant_id), 0, 0, 0
from payments where status = 'completed' and provider_env = 'production';
-- Trials ending per week (live free tenants): the size of what the flip decides.
select 'ftrial', to_char(date_trunc('week', a.current_period_end), 'YYYY-MM-DD'), count(*), 0, 0, 0
from tenant_plan_assignments a join tenants t on t.id = a.tenant_id join plans p on p.id = a.plan_id
where p.code = 'free' and a.status = 'active' and t.suspended_at is null and a.current_period_end > now() group by 2 order by 2;
-- Abuse suspensions by week.
select 'fabuse', to_char(date_trunc('week', suspended_at), 'YYYY-MM-DD'), count(*), 0, 0, 0
from tenants where suspension_reason like 'abuse%' and suspended_at > now() - interval '5 weeks' group by 2 order by 2;
SQL
)

net=""
if [ "$NET_SECS" -ge 10 ]; then net=$(./tenant-bandwidth.sh "$NET_SECS" 2>&1 | head -n 8); fi

CHURN="$churn" LOOPS="$loops" ROWS="$traffic_and_accounts" NET="$net" python3 -c '
import datetime, json, os, re
who = {}
rows = [l.split("|") for l in os.environ["ROWS"].splitlines() if l.strip()]
for r in rows:
    if r[0] == "slug": who[r[1]] = (r[2], r[3])
def tenant(ns):
    m = re.match(r"^kl-([0-9a-f]{8})-", ns)
    t = who.get(m.group(1)) if m else None
    return "%s (%s)" % t if t else "?"
def series(js, floor):
    out = []
    for x in json.loads(js)["data"]["result"]:
        v = float(x["value"][1])
        if v > floor: out.append((v, x["metric"].get("namespace", "?")))
    return sorted(out, reverse=True)

print("Kubeletto weekly review, %s" % datetime.date.today().isoformat())
print()
print("1. Network right now (a short sample; the ranking, not an invoice)")
print(os.environ["NET"] or "   skipped (NET_SECS=0)")
print()
c = series(os.environ["CHURN"], 200)
print("2. Cold-start churn: %d tenant namespace(s) above 200 pods in 24 h" % len(c))
print("   A scale-to-zero app that something pings every few minutes starts a fresh pod each time.")
for v, ns in c[:8]: print("   %5d pods  %-24s %s" % (v, ns, tenant(ns)))
print()
l = series(os.environ["LOOPS"], 50)
print("3. Crash loops: %d tenant namespace(s) above 50 container restarts in 24 h" % len(l))
for v, ns in l[:8]: print("   %5d restarts  %-24s %s" % (v, ns, tenant(ns)))
print()
print("4. Traffic: top services by requests, last 7 days")
print("   %9s %7s  %s" % ("requests", "errors", "tenant (plan)"))
for r in rows:
    if r[0] == "traffic": print("   %9d %6s%%  %s (%s)" % (int(r[4]), r[5], r[2], r[3]))
print()
print("5. Always-on: tenants whose pod was up about half the week or more (reserved CPU, not CPU used)")
print("   Around 500 on a free tenant is a pod up all week. With few requests that is a lead for a proxy or agent: look inside the pod before pausing.")
print("   %7s %9s  %s" % ("reserved", "requests", "tenant (plan)"))
for r in rows:
    if r[0] == "burn": print("   %7d %9d  %s (%s)" % (int(r[4]), int(r[5]), r[2], r[3]))
print()
print("6. Accounts")
print("   %-9s %7s %7s %9s" % ("plan", "tenants", "paused", "new, 7 d"))
for r in rows:
    if r[0] == "plan": print("   %-9s %7s %7s %9s" % (r[1], r[2], r[3], r[4]))
print()
print("7. Funnel (baseline for the 2026-12-07 read)")
print("   Signups by week of signup (abuse = suspended for abuse; activated = a deployment went active within 7 days):")
print("   %-11s %7s %6s %10s" % ("week of", "signups", "abuse", "activated"))
for r in rows:
    if r[0] == "fwk": print("   %-11s %7s %6s %10s" % (r[1], r[2], r[3], r[4]))
print("   Checkouts started in the last 30 days (tenants in brackets):")
pay = [r for r in rows if r[0] == "fpay"]
print("   " + (", ".join("%s %s (%s)" % (r[1], r[2], r[3]) for r in pay) if pay else "none"))
ren = dict((r[1], r[2]) for r in rows if r[0] == "frenew")
print("   Paying now %s, due to renew within 14 days %s, repeat payers %s, ever paid %s" % (
    ren.get("paying_now", "0"), ren.get("due_14d", "0"), ren.get("repeat_payers", "0"), ren.get("ever_paid", "0")))
print("   Trials ending, by week:")
print("   " + (", ".join("%s: %s" % (r[1], r[2]) for r in rows if r[0] == "ftrial") or "none"))
print("   Abuse suspensions, by week:")
print("   " + (", ".join("%s: %s" % (r[1], r[2]) for r in rows if r[0] == "fabuse") or "none"))
'
