"""Tenants: "is any Kubeletto tenant misbehaving or costing the platform?"

Method RED for a multi-tenant service (rate of pods and requests, errors as restarts
and throttled logs, duration only where Prometheus has it). Top row = the answer, with
thresholds that are the numbers in rules/k8s.yml and rules/network.yml.
Alert expressions mirrored here: K8sTenantColdStartChurn, K8sTenantContainerRestarting,
K8sTenantNamespaceWithoutNetworkPolicy, K8sTenantLogsThrottled, K8sLogsDropped,
K8sPodUnschedulable (the cluster-wide pod count only), TenantWorkerInboundSustained.

Provenance: no upstream mixin or vendor board was consulted. Every query is derived from
the live metric names of kube-state-metrics (job service_dmz, instance k3s), Vector's own
metrics (:30598), the kubelet-metrics exporter (:30599), node_exporter on k3s-worker and
Traefik, and from the alert rules above. The per-tenant network, CPU and memory panels mirror
no alert: they are the review view behind TenantWorkerInboundSustained and
K8sTenantColdStartChurn.

Facts the queries rely on (checked against the live Prometheus, 2026-11-09):
  * A tenant namespace is `kl-<8 hex>-<8 hex>`: opaque. The first 8 hex digits are the
    tenant id prefix that services/kubeletto/weekly-review.sh maps to a slug and plan.
    About 257 exist; about 17 hold a pod at any moment (apps scale to zero).
  * Tenant pods are Knative revisions: `svc-<8 hex>-<revision>-deployment-...`, with the
    containers `user-container` (the app) and `queue-proxy`. Every pod is its own
    kube-state-metrics series, so a pod that lived two minutes still counts for a day.
  * kube-state-metrics keeps the series of Succeeded/Failed pods, so memory requests are
    joined to the phase (Pending|Running), exactly as K8sNodeMemoryRequestsHigh does.
  * prometheus.yml drops kube_pod_status_{reason,ready,scheduled,qos_class},
    kube_pod_container_info, kube_pod_tolerations and kube_pod_container_resource_limits at
    ingest: no panel here may use them (old series linger in the retention window).
  * Since 2026-11-09 (ADR 0036) a small kubelet-metrics component exports four cAdvisor
    families per node on :30599 (job service_dmz, instances k3s and k3s-worker):
    container_cpu_usage_seconds_total and container_memory_working_set_bytes per
    {namespace, pod, container} (real containers only), and container_network_{receive,
    transmit}_bytes_total per POD (cAdvisor reports the pod's network namespace; interface
    eth0, container ""). The series with no namespace and no pod is the NODE's own eth0: the
    node total. hostNetwork pods (node-exporter, namespace node-metrics) share the node's
    namespace and so repeat the node total; tenant pods are never hostNetwork, and every
    per-tenant selector here is namespace=~"kl-.*" with pod!="", which also keeps the node
    series out. The label `node` of these series is the Proxmox host (pve2/pve3), never the
    Kubernetes node: that is `instance`.
  * The history of those series starts at 2026-11-09 and grows: a rate over [1h] or longer is
    diluted by the missing history, so time series use $__rate_interval and the "right now"
    tables and tiles use fixed 5 and 15 minute windows (a literal window, lint-exempt).
  * Pod byte counters are not wire bytes. A pod's eth0 also carries traffic that stays on its
    node (a pod asking the local coredns, a pod scraped by the node's own agents), which never
    touches the physical NIC, while the node's eth0 carries the overlay's headers. So a sum of
    pods can exceed the node line (the platform pods on the worker do), and "node minus tenant
    pods" is an estimate of what tenants do not explain, not an exact subtraction. The first
    scrape of a pod starts its counter: bytes a short-lived pod moved before that scrape are
    not counted, so a cold-start-heavy tenant is read as a lower bound.
  * Per-tenant REQUEST counts do not exist in Prometheus: Traefik serves every tenant app
    through one wildcard route (traefik-user-apps-...). They live in Postgres `usage_samples`
    (services/kubeletto/weekly-review.sh). Per-pod disk and I/O are not exported either (the
    filter keeps only the four families above).
  * The Vector throttle counter (component_id kubeletto_throttle_runtime) has NO live
    series: it is born with the first dropped event. Its per-tenant label name is
    therefore unverified.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, state_timeline, bargauge, table, text,
    steps,
)

D = 'job="service_dmz"'
KL = 'namespace=~"kl-.*"'
KM = 'job="service_dmz", port="30599"'          # the kubelet-metrics exporter (cAdvisor)
# Tenant pods only: namespace kl-.* and a pod, so the node's own namespace-less series never counts.
TP = KM + ', ' + KL + ', pod!=""'

# The numbers of the alert rules (rules/k8s.yml, rules/network.yml).
CHURN_PODS_PER_DAY = 200       # K8sTenantColdStartChurn (info, 1 h)
RESTARTS_PER_HOUR = 10         # K8sTenantContainerRestarting (warning, 3 h)
WORKER_INBOUND_BPS = 2.5e6     # TenantWorkerInboundSustained (warning, 2 h)

# K8sTenantColdStartChurn, verbatim: distinct pods of one tenant namespace in 24 h.
CHURN_24H = ('count by (namespace) (last_over_time(kube_pod_info{' + D + ', ' + KL + '}[1d]))')

# K8sTenantContainerRestarting, verbatim: restarts of the app container, summed over the namespace.
RESTARTS = ('sum by (namespace) (increase(kube_pod_container_status_restarts_total{'
            + D + ', ' + KL + ', container="user-container"}[%s]))')

# K8sTenantNamespaceWithoutNetworkPolicy, verbatim (the last line is the rule's guard: before
# kube-state-metrics exported networkpolicies every namespace would have none).
NO_POLICY = (
    '(kube_namespace_created{' + D + ', ' + KL + '}'
    ' unless on (namespace) kube_networkpolicy_created{' + D + ', networkpolicy="kubeletto-base-policy"})'
    ' and on () (count(kube_networkpolicy_created{' + D + '}) > 0)'
)

# Memory that pods hold by request (Pending|Running only), per tenant namespace.
MEM_REQUESTED = (
    'sum by (namespace) (kube_pod_container_resource_requests{' + D + ', ' + KL + ', resource="memory"}'
    ' * on (namespace, pod, uid) group_left ()'
    ' (kube_pod_status_phase{' + D + ', phase=~"Pending|Running"} == 1))'
)

# TenantWorkerInboundSustained, verbatim (rules/network.yml): the 30-minute window is the rule's
# on purpose (it smooths a pod that is woken every couple of minutes), so the panels that
# mirror it opt out of the rate-literal lint rule.
WORKER = 'instance="k3s-worker", device="eth0"'
WORKER_IN_RULE = 'rate(node_network_receive_bytes_total{' + WORKER + '}[30m]) * 8'
WORKER_IN = 'rate(node_network_receive_bytes_total{' + WORKER + '}[$__rate_interval]) * 8'
WORKER_OUT = 'rate(node_network_transmit_bytes_total{' + WORKER + '}[$__rate_interval]) * 8'
# The same interface as the kubelet counts it: the series with no namespace and no pod is the node's own.
NODE_IN = ('sum(rate(container_network_receive_bytes_total{' + KM + ', instance="k3s-worker", '
           'namespace="", pod=""}[$__rate_interval])) * 8')

# cAdvisor, per tenant namespace. `window` is a literal on purpose for the "right now" tables and
# tiles (the panels carry lint_ok rate-literal): the history is short, see the docstring.
NET_IN = 'container_network_receive_bytes_total'
NET_OUT = 'container_network_transmit_bytes_total'


def net_bits(metric: str, window: str, sel: str = TP, by: str = "namespace") -> str:
    """Bit/s of the selected pods' eth0, summed by `by` (empty = one total)."""
    agg = f"sum by ({by})" if by else "sum"
    return f'{agg} (rate({metric}{{{sel}}}[{window}])) * 8'


def cores(window: str, by: str = "namespace") -> str:
    return f'sum by ({by}) (rate(container_cpu_usage_seconds_total{{{TP}}}[{window}]))'


WS_NOW = f'sum by (namespace) (container_memory_working_set_bytes{{{TP}}})'

# Top tenants of the last 5 minutes (instant) and, for a time series, the set of tenants that are
# in the top N at the END of the dashboard's range (`@ end()`: one fixed set of lines, where a plain
# topk() re-ranks at every step and the legend grows as pods churn).
def top_now(metric: str, n: int) -> str:
    return f'topk({n}, sum by (namespace) (rate({metric}{{{TP}}}[$__rate_interval] @ end())))'


THROTTLE = ('vector_component_discarded_events_total{' + D + ', component_id="kubeletto_throttle_runtime"}')


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def _cell_colors(name: str, warn: float, color: str = "orange"):
    """A table value cell coloured by one threshold."""
    return _col(name, ("custom.cellOptions", {"type": "color-background"}),
                ("color", {"mode": "thresholds"}),
                ("thresholds", steps(("green", None), (color, warn))),
                ("decimals", 0))


def boards():
    b = board(
        uid="homelab-k8s-tenants", title="Tenants", folder="Kubernetes",
        description="Is any Kubeletto tenant misbehaving or costing the platform? Namespace and pod "
                    "counts, cold-start churn, crash loops, throttled logs, the network fence and the "
                    "worker's inbound traffic, and which tenants send, receive and use the most "
                    "(network, CPU and memory from the kubelet's cAdvisor). Open it after "
                    "K8sTenant* or TenantWorkerInboundSustained, and on the weekly tenant review. "
                    "Tenants are opaque ids (kl-<id>-<id>), so the per-tenant views are top-10 "
                    "tables. Per-tenant request counts are not in Prometheus.",
        method="red", filename="tenants", time_from="now-24h",
    )

    # --- the answer ---------------------------------------------------------------------
    b.row("Is a tenant misbehaving or costing the platform?", [
        stat(  # TenantWorkerInboundSustained
            "Worker inbound, 30 min", WORKER_IN_RULE, unit="bps",
            thresholds=steps(("green", None), ("red", WORKER_INBOUND_BPS)), legend="eth0 inbound",
            decimals=1, w=3, lint_ok=("rate-literal",),
            desc="Bit rate received on the Kubeletto tenant worker's eth0, as a 30-minute average "
                 "(rule TenantWorkerInboundSustained: above 2.5 Mbit/s for 2 hours, about 27 GB a "
                 "day). Red means a tenant pod is pulling from the internet or the worker is busy "
                 "inside the lab: eth0 also carries the cluster's own traffic. Next: the network "
                 "row below, then services/kubeletto/tenant-bandwidth.sh to name the tenant."),
        problem_stat(  # K8sTenantColdStartChurn (info)
            "Tenants over the churn line", 'count(' + CHURN_24H + ' > ' + str(CHURN_PODS_PER_DAY) + ')',
            warn_only=True, w=3,
            desc="Tenant namespaces that started more than 200 distinct pods in 24 hours (rule "
                 "K8sTenantColdStartChurn, severity info, 1 hour). A scale-to-zero app that something "
                 "pings every couple of minutes starts a fresh pod each time. Orange, not red: it is "
                 "for the weekly review, and most of these cost CPU, not bandwidth. The table below "
                 "names them."),
        problem_stat(  # K8sTenantContainerRestarting
            "Crash-looping tenants",
            'count(' + RESTARTS % '1h' + ' > ' + str(RESTARTS_PER_HOUR) + ')', w=3,
            desc="Tenant namespaces whose app container restarted more than 10 times in the last "
                 "hour, summed over the namespace's pods (rule K8sTenantContainerRestarting: 3 hours "
                 "running). A crash loop, not a deploy; the usual cause is a required secret that "
                 "the owner never set. The owner's to fix: tell them what the log says."),
        problem_stat(  # K8sTenantNamespaceWithoutNetworkPolicy
            "Namespaces without the fence", 'count(' + NO_POLICY + ')', w=3,
            desc="Tenant namespaces with no kubeletto-base-policy (rule "
                 "K8sTenantNamespaceWithoutNetworkPolicy, critical, 15 minutes). That policy "
                 "keeps tenant pods off the lab network and the shared Postgres and Valkey, so a "
                 "namespace without it is an isolation hole. A namespace seconds old is normal."),
        problem_stat(  # K8sTenantLogsThrottled
            "Log events throttled, 15 min",
            'sum(increase(' + THROTTLE + '[15m]))', w=3,
            desc="Log events Vector's per-tenant cap dropped in the last 15 minutes (rule "
                 "K8sTenantLogsThrottled: any drop). The tenant's `kubeletto logs` has holes for "
                 "that window; its app is unaffected. Reads 0 while no drop has ever happened: the "
                 "counter does not exist until the first one, so 0 here is also what an absent "
                 "series looks like (the Logs row shows whether Vector is scraped at all)."),
        problem_stat(  # K8sPodUnschedulable
            "Pods unschedulable", 'sum(kube_pod_status_unschedulable{' + D + '})', w=3,
            desc="Pods the scheduler refused, cluster-wide (rule K8sPodUnschedulable: 5 minutes). "
                 "When it is a tenant's pod, that tenant cannot start; the usual cause is memory "
                 "requests above what the worker can hand out (K8sNodeMemoryRequestsHigh). A brief "
                 "Pending during a cold start is normal and is not counted here."),
        stat(
            "Tenant inbound, total", net_bits(NET_IN, "$__rate_interval", by=""),
            unit="bps", decimals=1, graph=True, color_mode="value", legend="tenant pods inbound", w=3,
            desc="Bit rate received by all tenant pods together (kl-*), summed over their eth0 as the "
                 "kubelet's cAdvisor counts it, with the trend behind the number. It is what the "
                 "tenants' apps take in, from customers and from the internet; the 'Worker inbound, "
                 "30 min' tile is the whole node's eth0 and the one the alert watches. No alert rule: "
                 "a context number. These series exist since 2026-11-09, and a pod's first seconds are "
                 "not counted, so a tenant that is mostly cold starts reads low. The tenant namespace "
                 "count is on the fence row."),
        stat(
            "Tenant pods running",
            'count(kube_pod_status_phase{' + D + ', ' + KL + ', phase="Running"} == 1)',
            legend="pods", w=3, color_mode="value",
            desc="Tenant pods in phase Running right now (one pod holds the app and its queue-proxy "
                 "sidecar). Scale-to-zero makes it swing by a few every minute. No alert rule: "
                 "a context number."),
    ])

    # --- the network ------------------------------------------------------------------------
    b.row("Who is using the line? (the worker's network)", [
        timeseries(
            "k3s-worker network (TenantWorkerInboundSustained)",
            [(WORKER_IN_RULE, "inbound, 30 min average (the rule)"),
             (WORKER_IN, "inbound, short average"),
             (WORKER_OUT, "outbound")],
            unit="bps", w=8, h=8, legend="table", legend_calcs=("mean", "max"),
            thresholds=steps(("green", None), ("red", WORKER_INBOUND_BPS)), threshold_style="dashed",
            lint_ok=("rate-literal",),
            desc="Bit rate on the worker's eth0, where every tenant pod runs (rule "
                 "TenantWorkerInboundSustained: the 30-minute average above the dashed 2.5 Mbit/s for "
                 "2 hours). The WAN's inbound is nearly all this node, so a flat high inbound line is "
                 "the pattern of 2026-11-06, when one free app woken every 2 minutes pulled 40 to 50 GB a "
                 "day from the internet. eth0 also carries lab-internal traffic, so it can read "
                 "above the WAN."),
        timeseries(
            "Worker inbound against what customers send in",
            [(WORKER_IN, "k3s-worker eth0 inbound"),
             ('sum(rate(traefik_entrypoint_requests_bytes_total{' + D + ', entrypoint="websecure"}'
              '[$__rate_interval])) * 8', "customer request bodies at Traefik"),
             ('rate(ifHCInOctets{job="snmp_hex", ifName="ether1"}[$__rate_interval]) * 8',
              "WAN inbound (router)")],
            unit="bps", w=8, h=8, legend="table", legend_calcs=("mean", "max"),
            desc="The worker's inbound next to the bytes customers upload through the public edge "
                 "(Traefik request bodies) and the router's WAN inbound. The gap between the worker "
                 "line and the Traefik line is what the worker receives besides customers' uploads: "
                 "image pulls, what tenant apps fetch from the internet and the platform's own pods "
                 "(the next panel shows how much of it tenant pods account for). At the time of writing customers' "
                 "uploads are a rounding error against the worker's several Mbit/s, which is why the "
                 "hog is a pod pulling data, not traffic to it."),
        timeseries(
            "Worker inbound: tenant pods against the whole node",
            [(NODE_IN, "node eth0 (kubelet)"),
             (WORKER_IN, "node eth0 (node_exporter, cross-check)"),
             (net_bits(NET_IN, "$__rate_interval", sel=TP + ', instance="k3s-worker"', by=""),
              "tenant pods (all kl-*)"),
             (NODE_IN + ' - ' + net_bits(NET_IN, "$__rate_interval", sel=TP + ', instance="k3s-worker"', by=""),
              "node minus tenant pods")],
            unit="bps", w=8, h=8, legend="table", legend_calcs=("mean", "max"),
            desc="The worker's inbound bit rate from three angles: the node's own eth0 as the kubelet "
                 "counts it (the series with no namespace and no pod), the same interface from "
                 "node_exporter (a cross-check: over 15 minutes they agree within a few percent, "
                 "a wider gap means one source is stale) and the sum of all tenant pods. "
                 "'Node minus tenant pods' (kubelet node line minus tenants) is how much of the line tenants "
                 "do not account for: platform pods on the worker, image pulls and other host "
                 "traffic. Read it as an estimate, not an exact subtraction: a pod's counter also "
                 "holds traffic that never leaves the node (the local DNS), and the node's counter "
                 "holds the overlay's headers. A tenant line close to the node line would point at the "
                 "tenants; a tenant line far below it means most of the node's traffic is not tenant "
                 "pods. The series exist since 2026-11-09: wait for an hour of history before reading "
                 "a pattern. Outbound is in the tables below."),
    ])

    # --- who sends and receives the most -----------------------------------------------------
    # One ranking per table: A is the top 10 of the last 5 minutes, B and C attach the 15-minute
    # rate and the share of the tenants' total to the same ten namespaces.
    def net_table(title, metric, word, desc):
        top = 'topk(10, ' + net_bits(metric, "5m") + ')'
        return table(
            title,
            [(top, "", {}),
             ('(' + net_bits(metric, "15m") + ') and on (namespace) ' + top, "", {}),
             ('(' + net_bits(metric, "5m") + ') / scalar(' + net_bits(metric, "5m", by="") + ')'
              ' and on (namespace) ' + top, "", {})],
            columns=[("namespace", "Tenant namespace"), ("Value #A", word + ", 5 min"),
                     ("Value #B", word + ", 15 min"), ("Value #C", "Share of all tenants, 5 min")],
            overrides=[_col(word + ", 5 min", ("unit", "bps"), ("decimals", 1)),
                       _col(word + ", 15 min", ("unit", "bps"), ("decimals", 1)),
                       _col("Share of all tenants, 5 min", ("unit", "percentunit"), ("decimals", 0))],
            sort_by=word + ", 5 min", w=8, h=10,
            lint_ok=("rate-literal",),  # fixed 5 and 15 minute windows: the history is short, see the docstring
            desc=desc)

    b.row("Which tenants send and receive the most? (network, bit/s)", [
        net_table(
            "Top 10 tenants by inbound network", NET_IN, "Inbound",
            "The 10 tenant namespaces that received the most bits per second over the last 5 minutes, "
            "with their 15-minute average and their share of all tenants' inbound. Inbound is what "
            "the tenant's pods take in: customers' requests and whatever the app downloads. Read it "
            "next to the worker panel above: the tenants are one part of the node's line. A tenant "
            "near the top for a long time, with a high share, is the one to look at "
            "(services/kubeletto/tenant-bandwidth.sh names the slug). The series exist since "
            "2026-11-09 and a pod's first seconds are not counted, so a tenant that is mostly cold "
            "starts is read low. A literal 5 and 15 minute window, not the dashboard range."),
        net_table(
            "Top 10 tenants by outbound network", NET_OUT, "Outbound",
            "The 10 tenant namespaces that sent the most bits per second over the last 5 minutes, "
            "with their 15-minute average and their share of all tenants' outbound: responses to "
            "customers and whatever the app uploads. The same reading as the inbound table; a "
            "tenant high in both is busy, high only in outbound is serving content. The series "
            "exist since 2026-11-09. A literal 5 and 15 minute window, not the dashboard range."),
        timeseries(
            "Top 5 tenants by inbound, over time",
            [('(' + net_bits(NET_IN, "$__rate_interval") + ') and on (namespace) ' + top_now(NET_IN, 5),
              "{{namespace}}")],
            unit="bps", w=8, h=10, legend="table", legend_calcs=("mean", "max"),
            desc="Inbound bit rate of the 5 tenants that rank highest at the right edge of the "
                 "dashboard's range, one line per tenant namespace over the whole range (fixed set: "
                 "a tenant that was busy earlier but is quiet now is not drawn, the table is for "
                 "now). Spikes are a pod pulling data or a burst of traffic; a flat line is a "
                 "steady consumer. Start with the legend's mean. The data starts at 2026-11-09, so "
                 "a long range is mostly empty until the history grows."),
    ])

    # --- CPU and memory ----------------------------------------------------------------------------
    cpu_top = 'topk(10, ' + cores("5m") + ')'
    ws_top = 'topk(10, ' + WS_NOW + ')'
    b.row("Which tenants use the most CPU and memory?", [
        table(
            "Top 10 tenants by CPU (cores)",
            [(cpu_top, "", {}),
             ('(' + cores("15m") + ') and on (namespace) ' + cpu_top, "", {}),
             ('(' + cores("5m") + ') / scalar(sum(' + cores("5m") + '))' ' and on (namespace) ' + cpu_top, "", {})],
            columns=[("namespace", "Tenant namespace"), ("Value #A", "Cores, 5 min"),
                     ("Value #B", "Cores, 15 min"), ("Value #C", "Share of all tenants, 5 min")],
            overrides=[_col("Cores, 5 min", ("unit", "short"), ("decimals", 3)),
                       _col("Cores, 15 min", ("unit", "short"), ("decimals", 3)),
                       _col("Share of all tenants, 5 min", ("unit", "percentunit"), ("decimals", 0))],
            sort_by="Cores, 5 min", w=10, h=10, lint_ok=("rate-literal",),
            desc="CPU time the 10 busiest tenant namespaces used per second (1.0 = one full core), as a "
                 "5-minute and a 15-minute average, with their share of all tenants' CPU. Includes "
                 "both containers of every pod, the app and its queue-proxy. A scale-to-zero app "
                 "woken every couple of minutes shows its cold starts here as CPU. A tenant sustained "
                 "at a core or more is a runaway or a heavy app. The worker has 3.5 cores to hand "
                 "out. A literal 5 and 15 minute window: the series exist since 2026-11-09."),
        table(
            "Top 10 tenants by memory used and requested",
            [(ws_top, "", {}),
             ('(' + MEM_REQUESTED + ') and on (namespace) ' + ws_top, "", {}),
             ('(' + WS_NOW + ') / on (namespace) (' + MEM_REQUESTED + ') and on (namespace) ' + ws_top, "", {})],
            columns=[("namespace", "Tenant namespace"), ("Value #A", "Working set"),
                     ("Value #B", "Requested"), ("Value #C", "Used / requested")],
            overrides=[_col("Working set", ("unit", "bytes"), ("decimals", 0)),
                       _col("Requested", ("unit", "bytes"), ("decimals", 0)),
                       _col("Used / requested", ("unit", "percentunit"), ("decimals", 0))],
            sort_by="Working set", w=14, h=10,
            desc="The 10 tenant namespaces with the largest memory working set right now (what the "
                 "kernel cannot reclaim: the number the OOM killer and the kubelet's eviction act "
                 "on), next to what their pods reserve by request and the ratio. The worker hands "
                 "out about 3.6 GB; the node-level version of the request side is rule "
                 "K8sNodeMemoryRequestsHigh (90 %). Requests are overcommitted by design, so a ratio "
                 "above 100 % is normal for an app bursting past its small request; a tenant with a "
                 "large working set and a small request is the one that squeezes the node first. "
                 "A tenant that scales to zero uses and reserves nothing, so the table moves with "
                 "the traffic. A blank Requested is a pod that kube-state-metrics no longer lists "
                 "(it just scaled down) while the kubelet still reports its last memory."),
    ])

    # --- churn ---------------------------------------------------------------------------------
    b.row("Which tenants churn pods? (cold starts)", [
        table(
            "Top 10 tenants by pods in 24 h (K8sTenantColdStartChurn)",
            'topk(10, ' + CHURN_24H + ')',
            columns=[("namespace", "Tenant namespace"), ("Value", "Pods in 24 h")],
            overrides=[_cell_colors("Pods in 24 h", CHURN_PODS_PER_DAY)],
            sort_by="Pods in 24 h", w=12, h=9,
            desc="Distinct pods each tenant namespace started in the last 24 hours, the 10 highest "
                 "(rule K8sTenantColdStartChurn, severity info: orange above 200). 200 is a pod "
                 "every 7 minutes; about 715 means a request every 2 minutes. The 8 digits after "
                 "kl- are the tenant id prefix: services/kubeletto/weekly-review.sh maps them to a "
                 "slug and plan. Next: the network and CPU tables above, for whether the churn "
                 "costs bandwidth or CPU (TenantWorkerInboundSustained says so for the line)."),
        timeseries(
            "Tenant pods started per hour",
            [('count(last_over_time(kube_pod_created{' + D + ', ' + KL + '}[1h]) > time() - 3600)',
              "pods started in the trailing hour")],
            unit="short", w=12, h=9,
            desc="Distinct tenant pods created in the trailing hour (kube_pod_created of every pod "
                 "that left a series). An indirect cost signal: a woken scale-to-zero app starts a "
                 "pod every time, and each start makes the node pull or check the image. Image pulls "
                 "are the node's own traffic, so they are in the worker's line and in no tenant's "
                 "pod counters. At the time of writing it sits near 150 an hour: five tenants woken "
                 "every 2 minutes (the churn table beside it names them). A pod that lived less than "
                 "one scrape interval is missed."),
        timeseries(
            "Tenant pods and awake tenants",
            [('sum(kube_pod_status_phase{' + D + ', ' + KL + ', phase="Running"})', "pods Running"),
             ('sum(kube_pod_status_phase{' + D + ', ' + KL + ', phase="Pending"})', "pods Pending"),
             ('count(count by (namespace) (kube_pod_info{' + D + ', ' + KL + '}))', "tenants with a pod")],
            unit="short", w=24, h=7,
            desc="Tenant pods Running and Pending, and how many tenant namespaces hold any pod. "
                 "Pending is normal for a few seconds at a cold start; a Pending line that stays "
                 "above 0 is a tenant that cannot start (rule K8sPodUnschedulable counts the "
                 "unschedulable ones). The gap between tenants-with-a-pod and the 250-odd "
                 "tenant namespaces (the fence row counts them) is the scale-to-zero saving."),
    ])

    # --- restarts --------------------------------------------------------------------------------
    b.row("Are tenant containers crashing?", [
        table(
            "Tenants whose app container restarted in 24 h",
            [('topk(10, ' + RESTARTS % '1d' + ' > 0)', "", {}),
             (RESTARTS % '1h' + ' and on (namespace) (' + RESTARTS % '1d' + ' > 0)', "", {})],
            columns=[("namespace", "Tenant namespace"), ("Value #A", "Restarts in 24 h"),
                     ("Value #B", "Restarts in 1 h")],
            overrides=[_col("Restarts in 24 h", ("decimals", 0)),
                       _cell_colors("Restarts in 1 h", RESTARTS_PER_HOUR, "red")],
            sort_by="Restarts in 24 h", w=12, h=8, empty_ok=True,
            desc="Tenant namespaces whose app container (user-container) restarted at least once "
                 "in 24 hours, with the restarts of the last hour. The rule "
                 "(K8sTenantContainerRestarting) wants more than 10 an hour for 3 hours, shown "
                 "red. Empty is the normal state; a pod that is replaced rather than restarted "
                 "does not count. Next: kubectl -n <namespace> logs <pod> -c user-container "
                 "--previous."),
        timeseries(
            "Worst tenant, restarts in the trailing hour",
            [('max(' + RESTARTS % '1h' + ')', "worst tenant"),
             ('sum(' + RESTARTS % '1h' + ')', "all tenants")],
            unit="short", w=12, h=8, decimals=0,
            thresholds=steps(("green", None), ("red", RESTARTS_PER_HOUR)), threshold_style="dashed",
            desc="Restarts of tenant app containers in the trailing hour: the worst single tenant "
                 "and the total. The dashed line is the 10 an hour of rule "
                 "K8sTenantContainerRestarting, which must hold for 3 hours before it fires. A "
                 "line that sits at 0 is healthy. increase() extrapolates, so a single restart "
                 "can read slightly above 1."),
        bargauge(
            "Why containers waited or stopped, last 24 h",
            [('count by (reason) (last_over_time(kube_pod_container_status_waiting_reason{' + D + ', ' + KL
              + '}[1d]) == 1)', "waiting: {{reason}}"),
             ('count by (reason) (last_over_time(kube_pod_container_status_last_terminated_reason{' + D
              + ', ' + KL + '}[1d]) == 1)', "last ended: {{reason}}")],
            unit="short", w=24, h=6, empty_ok=True,
            desc="Containers of tenant pods by the reason they waited (ContainerCreating is every "
                 "cold start; CrashLoopBackOff, ImagePullBackOff or CreateContainerConfigError is a "
                 "tenant that cannot run) and by why their last run ended (OOMKilled is an app over "
                 "its memory limit; Error is a non-zero exit). Over 24 hours, so a reason that "
                 "appeared and cleared still shows. No alert watches tenant containers' waiting "
                 "reasons: K8sPlatformPodWaiting skips the kl-* namespaces on purpose."),
    ])

    # --- logs ---------------------------------------------------------------------------------------
    b.row("Are tenant logs throttled or lost?", [
        timeseries(
            "Throttled log events, per node (K8sTenantLogsThrottled)",
            [('sum by (instance, key) (increase(' + THROTTLE + '[15m]))', "{{instance}} {{key}}")],
            unit="short", w=8, h=7, empty_ok=True, decimals=0,
            desc="Log events Vector's per-tenant throttle dropped, per node, in a trailing 15 "
                 "minutes (rule K8sTenantLogsThrottled: any drop). Empty is the normal state: the "
                 "counter has no series until the first drop. The runbook says it carries a "
                 "per-tenant key label that names the tenant; that label is unverified (it has "
                 "never been born), so the legend shows it only if it exists. The cap is 6000 events "
                 "per 10 s per tenant per node."),
        timeseries(
            "Log events lost by failure (K8sLogsDropped)",
            [('sum by (instance, component_id) (increase(vector_component_discarded_events_total{' + D
              + ', intentional="false"}[15m]))', "dropped: {{instance}} {{component_id}}"),
             ('sum by (instance, component_id) (increase(vector_component_errors_total{' + D + '}[15m]))',
              "errors: {{instance}} {{component_id}}")],
            unit="short", w=8, h=7, empty_ok=True, decimals=0,
            desc="Events Vector lost because a sink or transform failed, not because a filter or "
                 "the throttle chose to (rule K8sLogsDropped: intentional=false, any in 15 minutes), "
                 "and Vector's component errors. Empty is the normal state. A line here means the "
                 "VictoriaLogs sink rejected or timed out; the lost lines do not come back."),
        timeseries(
            "Log events dropped on purpose, per filter",
            [('sum by (component_id) (rate(vector_component_discarded_events_total{' + D
              + ', intentional="true"}[$__rate_interval]))', "{{component_id}}")],
            unit="eps", w=8, h=7,
            desc="Events per second the filters discard by design: build logs and probe noise. "
                 "Healthy and steady; a throttle drop would appear here too, as kubeletto_throttle_"
                 "runtime. It doubles as proof that Vector is alive and counting."),
        state_timeline(
            "Vector scrape (is the throttle counter visible?)",
            [('up{' + D + ', port="30598"}', "{{instance}}")],
            w=24, h=4,
            desc="Whether Prometheus can read Vector's own metrics on each K3s node (target port "
                 "30598). When it is DOWN, the throttle and loss panels above are blind, not clean "
                 "(TargetDown fires for it after 5 minutes)."),
    ], collapsed=True)

    # --- the fence -------------------------------------------------------------------------------------
    b.row("Is every tenant fenced off from the lab network?", [
        table(
            "Tenant namespaces without kubeletto-base-policy",
            [('(' + NO_POLICY + ') * 1000', "", {})],
            columns=[("namespace", "Tenant namespace"), ("Value", "Created")],
            overrides=[_col("Created", ("unit", "dateTimeAsIso"))],
            sort_by="Created", w=12, h=7, empty_ok=True,
            desc="Tenant namespaces that carry no kubeletto-base-policy (rule "
                 "K8sTenantNamespaceWithoutNetworkPolicy: critical after 15 minutes). Empty is the "
                 "goal. A namespace created seconds ago is normal; one older than 15 minutes "
                 "means core's quota/policy reconciler did not run for it: re-apply the policy or "
                 "pause that tenant (the operator decides, it is customer-facing)."),
        timeseries(
            "Namespaces with the policy against tenant namespaces",
            [('count(kube_networkpolicy_created{' + D + ', ' + KL + ', networkpolicy="kubeletto-base-policy"})',
              "with kubeletto-base-policy"),
             ('count(kube_namespace_status_phase{' + D + ', ' + KL + ', phase="Active"} == 1)',
              "tenant namespaces")],
            unit="short", w=12, h=7, decimals=0,
            desc="Tenant namespaces that carry the base policy next to all tenant namespaces. The "
                 "two lines should lie on top of each other; a gap that opens when a tenant is "
                 "created and closes within minutes is the reconciler working, one that stays open "
                 "is the alert. If kube-state-metrics stops exporting networkpolicies the lower "
                 "line vanishes and the rule's guard keeps it quiet: look here."),
    ], collapsed=True)

    # --- requests ---------------------------------------------------------------------------------------
    b.row("Requests to tenant apps", [
        text("Requests, disk and I/O per tenant: not in Prometheus", (
            "Traefik reports one service for all tenant apps (`traefik-user-apps-...`), so this "
            "board can show **all tenants together** but not one tenant. The per-tenant request "
            "count is Kubeletto's `usage_samples` (metric `http_requests`, 5-minute windows) in "
            "Postgres; `services/kubeletto/weekly-review.sh` section 4 prints the top five with "
            "their error share. The Ingress (Traefik) board has the edge's rates, errors and "
            "latency by route. **Per-pod disk and I/O** are not exported either: the "
            "kubelet exporter keeps only CPU, memory and network."), w=10, h=8),
        timeseries(
            "Requests to tenant apps, all tenants (http)",
            [('sum(rate(traefik_service_requests_total{' + D + ', exported_service=~"traefik-user-apps-.*", '
              'protocol="http", code=~"2.."}[$__rate_interval]))', "2xx"),
             ('sum(rate(traefik_service_requests_total{' + D + ', exported_service=~"traefik-user-apps-.*", '
              'protocol="http", code=~"3.."}[$__rate_interval]))', "3xx"),
             ('sum(rate(traefik_service_requests_total{' + D + ', exported_service=~"traefik-user-apps-.*", '
              'protocol="http", code=~"4..", code!="499"}[$__rate_interval]))', "4xx (not 499)"),
             ('sum(rate(traefik_service_requests_total{' + D + ', exported_service=~"traefik-user-apps-.*", '
              'protocol="http", code="499"}[$__rate_interval]))', "499 client closed"),
             ('sum(rate(traefik_service_requests_total{' + D + ', exported_service=~"traefik-user-apps-.*", '
              'protocol="http", code=~"5.."}[$__rate_interval]))', "5xx")],
            unit="reqps", w=14, h=8, stack=True,
            desc="Requests per second reaching tenant apps through the wildcard route, by response "
                 "class (stacked: the parts sum to all http requests). The 5xx here are "
                 "Traefik's, mostly 504 (the tenant app did not answer in time: a cold start or a "
                 "slow app), and 499 is a client that left. See the Ingress board for the edge as a whole."),
    ], collapsed=True)
    return [b]
