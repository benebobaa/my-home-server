"""Cluster: "is the K3s cluster healthy, and does it have room?" (USE: the two nodes, their
reservations and their VMs are resources.) The 2-node K3s cluster of the PaaS Kubeletto:
`k3s` (the tainted server node, platform pods) and `k3s-worker` (tenant apps and builds),
as kube-state-metrics (:30931) and node_exporter (:9100, job service_dmz) report them.

Top row = the answer, one tile per K8s node alert, same numbers as rules/k8s.yml:
K8sNodeMemoryPressure, K8sPodUnschedulable, K8sNodeMemoryRequestsHigh (90 %) and
K8sNodeCapacityTrigger (85 % for 7 days), plus HostMemoryLow and TargetDown for the VMs.
Below: the scheduler's room (memory and CPU requests against allocatable), what the pods
really use next to it (the kubelet's cAdvisor), the 7-day trigger trend (collapsed), pods and
namespaces, the two VMs' USE, and the telemetry's own health.

Provenance: the queries are derived from the live metric names and labels (checked against
the lab's Prometheus on 2026-11-09) and from the alert rules above. No upstream mixin or
vendor dashboard was consulted.

Facts that shaped the queries:
- Labels: every kube-state-metrics series carries `node` (the Proxmox host of the target,
  pve2) and the Kubernetes node arrives as `exported_node` (k3s, k3s-worker). Legends use
  exported_node, never node. node_exporter's `instance` has the same two values, so one
  variable ($node, from kube_node_info) filters both kinds of series.
- The memory/CPU "requested" figure joins the request series to the pod phase
  (Pending|Running), as K8sNodeMemoryRequestsHigh does: kube-state-metrics keeps the request
  series of Succeeded and Failed pods, and only the join keeps finished build pods out of the
  reservation. Today the join changes nothing (no finished pod holds a series); it is there
  so the board reads like the rule when a build finishes.
- kube_pod_status_unschedulable has no series while no pod is unschedulable, so its tiles
  are built to read 0 (and n/a when kube-state-metrics itself is gone).
- Cost of the capacity trigger: K8sNodeCapacityTrigger evaluates
  min_over_time((requests / allocatable)[7d:30m]) every 30 s. Pod churn is high (about 26,000
  pod series and 52,000 memory-request series over 7 days), so that one expression takes
  about 5 s (the k8s rule group peaks at 15 s per evaluation; the plain ratio takes 0.1 s).
  A 7-day range query of the same ratio is no cheaper (3 to 4.5 s: the cost is reading the
  week's pod series, not the number of steps). So nothing on this board runs it all the time:
  the always-on tile is the instantaneous ratio (0.1 s) plus the trigger alert's own
  ALERTS state (free), and the 7-day trend lives in a collapsed row (Grafana does not query a
  collapsed row until it is opened) with a 7-day panel time range at the rule's 30-minute step.
  A recording rule for the ratio would make the rule and the panel cheap; none exists yet.
- Since 2026-11-09 (ADR 0036) the kubelet-metrics exporter (:30599, job service_dmz) gives the
  pods' real use: container_memory_working_set_bytes (gauge) and container_cpu_usage_seconds_total
  (counter) per {namespace, pod, container}. Its series carry `instance` = the Kubernetes node
  (k3s, k3s-worker), where kube-state-metrics' carry `exported_node` (and `instance` k3s on both):
  the use side is summed by `instance` and relabelled to `exported_node` to meet requests and
  allocatable, and `$node` filters both because the values are the same two names. The label
  `node` is the Proxmox host, never the Kubernetes node. The sum covers the pods' containers
  only: kubelet, containerd, k3s and the kernel are not in it, so it sits below the VM's own
  used memory (node_exporter). The history grows from that day; the instant bars use a fixed
  5 minute CPU window.
- Still missing: per-pod disk and I/O (the exporter keeps CPU, memory and network only), and
  container limits (dropped at ingest), so "distance to an OOM kill" is not on this board.
"""
from lib import (
    board, stat, problem_stat, timeseries, bargauge, table, state_timeline,
    var_query, steps, hi_bad, UP_DOWN,
)

# --- selectors -----------------------------------------------------------------
D = 'job="service_dmz"'
NODE = ', exported_node=~"$node"'          # filter for the per-node panels
INST = f'{D}, port="9100", instance=~"$node"'  # node_exporter of the selected VMs
# node_exporter metrics in job service_dmz are the k3s VMs' (port 9100 only: the `ai` VM's
# series carry no port label). HostMemoryLow / HostFilesystemFull scope: job service_dmz.
NIC = 'device=~"nic[0-9]+|eth[0-9]+|en[a-z0-9]+"'
FS = 'fstype=~"ext4|xfs|zfs|btrfs|vfat"'   # HostFilesystemFull's filter

# Pods that hold a reservation: Pending (scheduled) and Running, as K8sNodeMemoryRequestsHigh.
HOLDS = (f'* on (namespace, pod, uid) group_left ()'
         f' (kube_pod_status_phase{{{D}, phase=~"Pending|Running"}} == 1)')


def requested(resource: str, flt: str = "") -> str:
    return (f'sum by (exported_node) (kube_pod_container_resource_requests'
            f'{{{D}, resource="{resource}"{flt}}} {HOLDS})')


def allocatable(resource: str, flt: str = "") -> str:
    return f'kube_node_status_allocatable{{{D}, resource="{resource}"{flt}}}'


def ratio(resource: str, flt: str = "") -> str:
    """Requests / allocatable per node: K8sNodeMemoryRequestsHigh's expression, verbatim for memory."""
    return f'{requested(resource, flt)} / on (exported_node) {allocatable(resource, flt)}'


KM = f'{D}, port="30599"'   # the kubelet-metrics exporter (cAdvisor)


def used(kind: str) -> str:
    """What the pods of each node use, by `instance` (= the Kubernetes node on the cAdvisor series)."""
    if kind == "memory":
        return f'sum by (instance) (container_memory_working_set_bytes{{{KM}, instance=~"$node"}})'
    return f'sum by (instance) (rate(container_cpu_usage_seconds_total{{{KM}, instance=~"$node"}}[$__rate_interval]))'


# A fixed 5 minute window for the instant bars (lint_ok rate-literal on the panel): the history is young.
CPU_NOW = f'sum by (instance) (rate(container_cpu_usage_seconds_total{{{KM}, instance=~"$node"}}[5m]))'


def as_node(expr: str) -> str:
    """Relabel `instance` to `exported_node`, the label requests and allocatable are keyed by."""
    return f'label_replace({expr}, "exported_node", "$1", "instance", "(.*)")'


def _node_style():
    """Overrides for the use/requested/allocatable time series: colour by node, dash by kind."""
    def rx(pattern, *props):
        return {"matcher": {"id": "byRegexp", "options": pattern},
                "properties": [{"id": i, "value": v} for i, v in props]}
    dash = {"fill": "dash", "dash": [10, 10]}
    dots = {"fill": "dash", "dash": [2, 6]}
    return [
        rx("^k3s .*", ("color", {"mode": "fixed", "fixedColor": "blue"})),
        rx("^k3s-worker .*", ("color", {"mode": "fixed", "fixedColor": "purple"})),
        rx(".* requested$", ("custom.lineStyle", dash), ("custom.fillOpacity", 0), ("custom.lineWidth", 2)),
        rx(".* allocatable$", ("custom.lineStyle", dots), ("custom.fillOpacity", 0), ("custom.lineWidth", 2)),
    ]


def zero_unless_gone(expr: str) -> str:
    """`expr`, or 0 while kube-state-metrics answers; no data (n/a) when it does not."""
    return f'{expr} or 0 * count(kube_node_info{{{D}}})'


def by_node(expr: str) -> str:
    """One row per selected node, keyed (exported_node, kubelet_version), for the merged node table."""
    return (f'max by (exported_node, kubelet_version) (({expr})'
            f' * on (exported_node) group_left (kubelet_version) kube_node_info{{{D}{NODE}}})')


def _cells(**texts):
    """Value mappings for a table column: value -> (text, colour)."""
    return [{"type": "value", "options": {
        v: {"text": t, "color": c, "index": i} for i, (v, (t, c)) in enumerate(texts.items())}}]


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def _cell_override(name: str, mappings: list):
    return _col(name, ("mappings", mappings), ("custom.cellOptions", {"type": "color-background"}))


READY_MAP = [{"type": "value", "options": {
    "0": {"text": "NOT READY", "color": "red", "index": 0},
    "1": {"text": "ALL READY", "color": "green", "index": 1},
}}]
TRIGGER_MAP = [
    {"type": "value", "options": {"0": {"text": "clear", "color": "green", "index": 0}}},
    {"type": "range", "options": {"from": 1, "to": 1000,
                                  "result": {"text": "TRIGGERED", "color": "orange", "index": 1}}},
]


def _line_at(value: float) -> dict:
    """A dashed boundary line is drawn in the colour of the step that starts there."""
    return steps(("green", None), ("red", value))


def boards():
    b = board(
        uid="homelab-k8s-cluster", title="Cluster", folder="Kubernetes",
        description="Is the K3s cluster healthy, and does it have room? Open it after a K8sPodUnschedulable, "
                    "K8sNodeMemoryRequestsHigh, K8sNodeMemoryPressure or K8sNodeCapacityTrigger alert, "
                    "or on the weekly review: nodes, memory and CPU requests against allocatable, "
                    "what the pods really use next to them, pods and namespaces, and the two VMs. "
                    "The top row is cluster-wide; the Node variable filters the panels below it.",
        method="use", filename="cluster",
        variables=[var_query("node", "Node", f"label_values(kube_node_info{{{D}}}, exported_node)",
                             multi=True, include_all=True)],
    )

    b.row("Is the cluster OK?", [
        stat(
            "Nodes Ready", f'min(kube_node_status_condition{{{D}, condition="Ready", status="true"}})',
            unit="none", thresholds=UP_DOWN, mappings=READY_MAP,
            desc="Whether every node's Ready condition is true. NOT READY means the kubelet of that "
                 "node is gone or unhealthy: pods on it are not served. No rule watches Ready itself "
                 "(a dead VM shows up as TargetDown); read it with the scrape-targets tile. "
                 "n/a means kube-state-metrics is not answering.", w=3),
        problem_stat(
            "Memory pressure", f'sum(kube_node_status_condition{{{D}, condition="MemoryPressure", status="true"}})',
            no_value="n/a", empty_ok=False,
            desc="Nodes under MemoryPressure: the kubelet says it is short of memory and evicts pods, "
                 "tenant apps first (rule K8sNodeMemoryPressure, critical, 2 minutes). Any red here "
                 "is tenants being killed now (docs/runbooks/alerts.md, K8sNodeMemoryPressure).", w=3),
        problem_stat(
            "Unschedulable pods",
            zero_unless_gone(f'sum(kube_pod_status_unschedulable{{{D}}})'),
            no_value="n/a", empty_ok=False,
            desc="Pods the scheduler refuses because no node has room or a selector or taint does "
                 "not fit (rule K8sPodUnschedulable: above 0 for 5 minutes, warning). A tenant app "
                 "or a build cannot start. kube-state-metrics only has the series while a pod is "
                 "unschedulable, so the tile reads 0 otherwise. A pod that is merely Pending for a few "
                 "seconds (image pull) does not count.", w=3),
        stat(
            "Memory requested, fullest node", f'max({ratio("memory")})', unit="percentunit", decimals=0,
            thresholds=hi_bad(0.85, 0.90),
            desc="Memory reserved by pods (requests of Running and scheduled Pending pods) over what "
                 "the fullest node can hand out (allocatable). One tile, two rules: red above 90 % "
                 "held for 15 minutes is K8sNodeMemoryRequestsHigh (the next build or cold start has "
                 "no room); orange from 85 % is where K8sNodeCapacityTrigger starts counting. That "
                 "rule needs the 7-day minimum above 85 %, which is the collapsed row below. Free "
                 "RAM can look fine while this is high: the scheduler counts requests, not use.", w=3),
        stat(
            "Add-a-node trigger",
            'count(ALERTS{alertname="K8sNodeCapacityTrigger", alertstate=~"pending|firing"}) or vector(0)',
            unit="none", thresholds=steps(("green", None), ("orange", 1)), mappings=TRIGGER_MAP,
            desc="TRIGGERED when rule K8sNodeCapacityTrigger is pending or firing: a node's memory "
                 "requests stayed above 85 % of allocatable at every 30-minute reading for 7 days, "
                 "Kubeletto's signal to plan a new node (info, not an incident; the weekly "
                 "queue). Read from the alert's own state because recomputing the 7-day minimum "
                 "costs about 5 s of Prometheus time on every refresh; the trend behind it is in the "
                 "collapsed Capacity row.", w=3),
        stat(
            "VM memory available, lowest",
            f'min(node_memory_MemAvailable_bytes{{{D}}} / node_memory_MemTotal_bytes{{{D}}})',
            unit="percentunit", decimals=0, thresholds=steps(("red", None), ("green", 0.10)),
            desc="Lowest MemAvailable / MemTotal of the two K3s VMs (rule HostMemoryLow: under 10 % "
                 "for 15 minutes). The warning before the kubelet evicts tenant apps. It is the VM's "
                 "own view (cache excluded) and complements the requests tile: high requests with "
                 "free RAM is a scheduling squeeze, low available RAM is real memory use.", w=3),
        problem_stat(
            "K3s scrape targets down", f'count(up{{{D}, instance=~"k3s.*"}} == 0) or vector(0)',
            empty_ok=False,
            desc="Scrape targets of the K3s VMs that fail: kube-state-metrics (:30931), node_exporter "
                 "(:9100), Traefik (:30910), Vector (:30598) and Kubeletto core (:30080), on k3s and "
                 "k3s-worker (rule TargetDown, 5 minutes). Every panel on this board is stale when "
                 "kube-state-metrics is among them. The `ai` VM is in the same job and is off by "
                 "design, so it is not counted.", w=3),
        problem_stat(
            "Pods Failed or Unknown", f'sum(kube_pod_status_phase{{{D}, phase=~"Failed|Unknown"}})',
            warn_only=True, no_value="n/a", empty_ok=False,
            desc="Pods in phase Failed or Unknown. Evicted pods stay Failed until Kubernetes "
                 "garbage-collects them, so this follows a MemoryPressure episode; Unknown means a "
                 "node lost contact. No alert rule. The table in the Pods row names them while a "
                 "Pending or Failed pod exists.", w=3),
    ])

    b.row("Is there room? (the scheduler's view)", [
        timeseries(
            "Memory requested / allocatable, per node",
            [(ratio("memory", NODE), "{{exported_node}}")],
            desc="Memory requests of Running and scheduled Pending pods over each node's allocatable "
                 "memory, over the dashboard's range. Dashed lines: 85 % (orange) is where "
                 "K8sNodeCapacityTrigger starts counting, 90 % (red) is K8sNodeMemoryRequestsHigh "
                 "(held 15 minutes). k3s carries the platform, k3s-worker the tenant apps and "
                 "builds. Tenant requests are overcommitted by design (Kubeletto D9), so this line, "
                 "not free RAM, shows when the next cold start would not fit.",
            unit="percentunit", max=1, w=12, h=8,
            thresholds=hi_bad(0.85, 0.90), threshold_style="dashed"),
        timeseries(
            "CPU requested / allocatable, per node",
            [(ratio("cpu", NODE), "{{exported_node}}")],
            desc="CPU requests of Running and scheduled Pending pods over each node's allocatable "
                 "cores. CPU is compressible: a node can run at its CPU limit and only slow down, "
                 "but near 100 % the scheduler refuses new pods (Insufficient cpu), which is "
                 "K8sPodUnschedulable. No alert rule on the ratio itself.",
            unit="percentunit", max=1, w=12, h=8),
        bargauge(
            "Memory headroom, per node",
            [(f'{allocatable("memory", NODE)} - on (exported_node) {requested("memory", NODE)}',
              "{{exported_node}}")],
            desc="Allocatable memory minus what pods have reserved: how much more the scheduler can "
                 "hand out on each node right now. Compare it with the largest thing you expect "
                 "to start (a build is 512 Mi). Near zero is where tenant pods go Pending "
                 "(K8sPodUnschedulable).",
            unit="bytes", w=12, h=6),
    ])

    b.row("What do the pods really use? (next to the scheduler's view)", [
        timeseries(
            "Memory: used by pods, requested, allocatable",
            [(used("memory"), "{{instance}} used by pods"),
             (requested("memory", NODE), "{{exported_node}} requested"),
             (allocatable("memory", NODE), "{{exported_node}} allocatable")],
            unit="bytes", w=9, h=9, overrides=_node_style(),
            legend="table", legend_calcs=("lastNotNull",),
            desc="Per node, three lines: the memory working set of all its pods (solid, filled: what the "
                 "kernel cannot reclaim, summed over the pods' containers), the memory the pods request "
                 "(dashed: the scheduler's book, rule K8sNodeMemoryRequestsHigh at 90 % of allocatable) "
                 "and the node's allocatable memory (dotted: the ceiling). Used well under requested is "
                 "reserved room that is not used (by design for tenants: requests are overcommitted); "
                 "used above requested means pods take more than they reserved, so the real headroom is "
                 "smaller than the requests ratio says. Used approaching allocatable is the node "
                 "running out of memory (K8sNodeMemoryPressure). The pods' sum leaves out the kubelet, "
                 "containerd and the kernel: the VM's own used memory is higher (Infrastructure > "
                 "Nodes). The series exist since 2026-11-09."),
        timeseries(
            "CPU (cores): used by pods, requested, allocatable",
            [(used("cpu"), "{{instance}} used by pods"),
             (requested("cpu", NODE), "{{exported_node}} requested"),
             (allocatable("cpu", NODE), "{{exported_node}} allocatable")],
            unit="short", decimals=2, w=9, h=9, overrides=_node_style(),
            legend="table", legend_calcs=("lastNotNull",),
            desc="Per node, in cores: the CPU time its pods use per second (solid, filled), what they "
                 "request (dashed) and the node's allocatable cores (dotted). CPU is compressible: "
                 "used above requested is fine while the node has spare cores; used near allocatable "
                 "is a node that is CPU-bound, and pods slow down rather than die. The pods' "
                 "sum leaves out the kubelet, containerd and the k3s server: the VM's CPU "
                 "utilisation (the compact VM row below) is higher. No alert rule. The series exist "
                 "since 2026-11-09."),
        bargauge(
            "Pods' use and requests, share of allocatable",
            [(f'({as_node(used("memory"))}) / on (exported_node) {allocatable("memory", NODE)}',
              "{{exported_node}} memory used"),
             (ratio("memory", NODE), "{{exported_node}} memory requested"),
             (f'({as_node(CPU_NOW)}) / on (exported_node) {allocatable("cpu", NODE)}',
              "{{exported_node}} CPU used"),
             (ratio("cpu", NODE), "{{exported_node}} CPU requested")],
            unit="percentunit", max=1, w=6, h=9, thresholds=hi_bad(0.85, 0.90), lint_ok=("rate-literal",),
            desc="Right now, per node, as a share of what the node can hand out: the pods' memory "
                 "working set and memory requests, and the pods' CPU use (a 5-minute average) and "
                 "CPU requests. The colours are the 85 % and 90 % of K8sNodeCapacityTrigger and "
                 "K8sNodeMemoryRequestsHigh: they apply to the 'memory requested' bars (the "
                 "rule) and are only a reading aid on the other three. Requested above used is "
                 "overcommit headroom the tenants share; used above requested is the squeeze."),
    ])

    # The trigger trend. Collapsed on purpose: see the module docstring (cost). The panel
    # asks Prometheus for 7 days at the rule's own 30-minute step, only while the row is open.
    capacity = timeseries(
        "Memory requested / allocatable, 7 days",
        [(ratio("memory", NODE), "{{exported_node}}", {"interval": "30m"})],
        desc="The same ratio as the tile and the chart above, over the last 7 days at the 30-minute "
             "step of K8sNodeCapacityTrigger. The rule fires when the 7-day MINIMUM of this line "
             "(its 'min' in the legend table) stays above 85 % (the orange dashed line) and the node "
             "is at least a week old: one quiet half hour clears it. The legend's min is "
             "therefore the number the trigger tests. This panel is heavy: the week holds about 26,000 "
             "pod series, so the query takes 3 to 5 seconds, as much as the rule's own subquery, "
             "which runs every 30 seconds. That is why it is in a collapsed row (not queried until "
             "opened) and the tile reads the alert instead.",
        unit="percentunit", max=1, w=24, h=9,
        thresholds=hi_bad(0.85, 0.90), threshold_style="dashed",
        legend="table", legend_calcs=("min", "mean", "max", "lastNotNull"))
    capacity.spec["timeFrom"] = "7d"  # panel time override: independent of the board's range
    b.row("Capacity trigger, 7 days (heavy: opens on demand)", [capacity], collapsed=True)

    b.row("Nodes, pods and namespaces", [
        table(
            "Nodes",
            [by_node(f'max by (exported_node) (kube_node_status_condition{{{D}, condition="Ready", status="true"}})'),
             by_node(f'max by (exported_node) (kube_node_status_condition{{{D}, condition="MemoryPressure", status="true"}})'),
             by_node(f'max by (exported_node) (kube_node_status_condition{{{D}, condition="DiskPressure", status="true"}})'),
             by_node(f'max by (exported_node) (kube_node_status_condition{{{D}, condition="PIDPressure", status="true"}})'),
             by_node(f'max by (exported_node) (kube_node_spec_unschedulable{{{D}}})'),
             by_node(f'count by (exported_node) (kube_pod_info{{{D}}}'
                     f' * on (namespace, pod, uid) group_left () (kube_pod_status_phase{{{D}, phase="Running"}} == 1))'),
             by_node(ratio("memory")),
             by_node(ratio("cpu"))],
            desc="One row per node: whether the kubelet is Ready, whether it reports memory, disk or "
                 "PID pressure (MemoryPressure is rule K8sNodeMemoryPressure; DiskPressure on the "
                 "worker is the image and build-cache disk filling: pods get evicted), whether the node "
                 "is cordoned (unschedulable: no new pods land on it, which strands tenants if it is "
                 "the worker), how many pods run on it (limit 110), and its memory and CPU "
                 "requests over allocatable. Red cells are the ones to act on. k3s is the tainted "
                 "server node (platform pods); k3s-worker takes the tenant apps and builds.",
            columns=[("exported_node", "Node"), ("kubelet_version", "Kubelet"),
                     ("Value #A", "Ready"), ("Value #B", "Memory pressure"),
                     ("Value #C", "Disk pressure"), ("Value #D", "PID pressure"),
                     ("Value #E", "Cordoned"), ("Value #F", "Running pods"),
                     ("Value #G", "Memory requested"), ("Value #H", "CPU requested")],
            overrides=[
                _cell_override("Ready", _cells(**{"1": ("Ready", "green"), "0": ("NOT READY", "red")})),
                _cell_override("Memory pressure", _cells(**{"0": ("no", "green"), "1": ("YES", "red")})),
                _cell_override("Disk pressure", _cells(**{"0": ("no", "green"), "1": ("YES", "red")})),
                _cell_override("PID pressure", _cells(**{"0": ("no", "green"), "1": ("YES", "red")})),
                _cell_override("Cordoned", _cells(**{"0": ("no", "green"), "1": ("cordoned", "orange")})),
                _col("Memory requested", ("unit", "percentunit"), ("decimals", 0)),
                _col("CPU requested", ("unit", "percentunit"), ("decimals", 0)),
            ],
            sort_by="Node", descending=False, w=24, h=5),
        timeseries(
            "Pods by phase",
            [(f'sum by (phase) (kube_pod_status_phase{{{D}}} == 1)', "{{phase}}")],
            desc="Pods in each phase across all namespaces; the phases sum to every pod "
                 "kube-state-metrics knows. Running is the norm. Tenant apps scale to zero, so Pending "
                 "blips (image pull, a few seconds) and Succeeded (finished builds) are normal; "
                 "Failed or Unknown that stay are not. All namespaces: the platform's own pods are on Platform workloads.",
            unit="short", stack=True, w=8, h=8),
        timeseries(
            "Pending and unschedulable pods",
            [(f'sum(kube_pod_status_phase{{{D}, phase="Pending"}})', "Pending"),
             (zero_unless_gone(f'sum(kube_pod_status_unschedulable{{{D}}})'), "Unschedulable")],
            desc="Pods waiting to start, and the subset the scheduler has marked unschedulable "
                 "(rule K8sPodUnschedulable: above 0 for 5 minutes). Pending spikes of seconds are "
                 "cold starts; a Pending line that stays up, or any Unschedulable above 0, is a tenant "
                 "that cannot start. The unschedulable series only exists while a pod is stuck, so "
                 "the line reads 0 otherwise.",
            unit="short", w=8, h=8),
        table(
            "Pods not Running, by name",
            f'kube_pod_status_phase{{{D}, phase=~"Pending|Failed|Unknown"}} == 1',
            desc="Every pod that is Pending, Failed or Unknown right now, any namespace. Empty is the "
                 "good state; one Pending tenant pod (kl-*) is a cold start in progress. A "
                 "platform namespace here for more than a minute is worth a look: Platform workloads "
                 "names the reason. Failed pods are usually evictions.",
            columns=[("namespace", "Namespace"), ("pod", "Pod"), ("phase", "Phase")],
            sort_by="Namespace", descending=False, w=8, h=8, empty_ok=True),
        timeseries(
            "Namespaces",
            [(f'count(kube_namespace_status_phase{{{D}, phase="Active", namespace=~"kl-.*"}} == 1)', "tenant (kl-*)"),
             (f'count(kube_namespace_status_phase{{{D}, phase="Active", namespace!~"kl-.*"}} == 1)', "platform and system"),
             (f'sum(kube_namespace_status_phase{{{D}, phase="Terminating"}})', "Terminating")],
            desc="Active namespaces: one per Kubeletto tenant (kl-*), plus the platform and system "
                 "ones. Growth is signups; a Terminating namespace that stays above 0 is a delete "
                 "that cannot finish (a finalizer or an unreachable API object). No alert rule.",
            unit="short", w=24, h=6),
    ])

    b.row("The two VMs (USE, compact: Infrastructure > Nodes has the full set)", [
        timeseries(
            "CPU utilisation",
            [(f'100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{{mode="idle", {INST}}}[$__rate_interval])))',
              "{{instance}}")],
            desc="Share of CPU time not idle, averaged over the VM's 4 cores (iowait and steal count "
                 "as busy). Sustained near 100 means the VM is CPU-bound; build bursts are normal. "
                 "No alert rule. The full set (load, I/O pressure, disk latency, conntrack) is on "
                 "Infrastructure > Nodes.",
            unit="percent", max=100, w=8, h=7,
            links=[("Infrastructure > Nodes", "/d/homelab-infra-nodes")]),
        timeseries(
            "Memory available",
            [(f'node_memory_MemAvailable_bytes{{{INST}}} / node_memory_MemTotal_bytes{{{INST}}}', "{{instance}}")],
            desc="MemAvailable / MemTotal per VM. The dashed line is the HostMemoryLow threshold "
                 "(10 %, held 15 minutes). Falling toward it means tenant pods are about to be "
                 "evicted by the kubelet (it evicts at about 100 Mi available).",
            unit="percentunit", max=1, w=8, h=7,
            thresholds=_line_at(0.10), threshold_style="dashed"),
        timeseries(
            "Pressure stall (PSI)",
            [(f'rate(node_pressure_cpu_waiting_seconds_total{{{INST}}}[$__rate_interval])', "{{instance}} cpu"),
             (f'rate(node_pressure_memory_waiting_seconds_total{{{INST}}}[$__rate_interval])', "{{instance}} memory some"),
             (f'rate(node_pressure_memory_stalled_seconds_total{{{INST}}}[$__rate_interval])', "{{instance}} memory full")],
            desc="Share of time tasks stalled waiting for CPU, and for memory ('some' = at least one "
                 "task, 'full' = all non-idle tasks): the direct saturation signal. A few percent "
                 "is normal; tens of percent sustained is contention or reclaim hurting. "
                 "No alert rule.",
            unit="percentunit", max=1, w=8, h=7),
        timeseries(
            "OOM kills",
            [(f'increase(node_vmstat_oom_kill{{{INST}}}[$__rate_interval])', "{{instance}}")],
            desc="Processes the kernel's out-of-memory killer ended in each window (the memory error "
                 "counter): a tenant app hitting its own limit counts too, because the kill happens in "
                 "its cgroup. Anything above 0 is an app or a build killed for memory. No alert rule.",
            unit="short", w=8, h=7),
        bargauge(
            "Filesystem free",
            [(f'node_filesystem_avail_bytes{{{INST}, {FS}}} / node_filesystem_size_bytes{{{INST}, {FS}}}',
              "{{instance}} {{mountpoint}}")],
            desc="Free-space ratio of every mount (rule HostFilesystemFull: red under 15 % for 15 "
                 "minutes). The worker's root disk holds the tenant images and the build cache; "
                 "full, the kubelet reports DiskPressure and evicts pods. /mnt/registry on k3s is the "
                 "image registry's disk. /boot/efi sits at about 93 % free.",
            unit="percentunit", max=1, w=8, h=7, thresholds=steps(("red", None), ("green", 0.15))),
        timeseries(
            "Network throughput",
            [(f'rate(node_network_receive_bytes_total{{{INST}, {NIC}}}[$__rate_interval])', "{{instance}} receive"),
             (f'rate(node_network_transmit_bytes_total{{{INST}, {NIC}}}[$__rate_interval])', "{{instance}} transmit")],
            desc="Bytes per second on each VM's eth0 (pod veth and bridge devices repeat the same bytes "
                 "and are left out). The worker's receive line is tenant image pulls and "
                 "builds: see Network > Router and WAN for the WAN side and the ISP quota. "
                 "No alert rule here.",
            unit="Bps", w=8, h=7),
    ])

    b.row("Is the cluster's telemetry healthy?", [
        state_timeline(
            "Scrape targets of the K3s VMs",
            [(f'up{{{D}, instance=~"k3s.*"}}', "{{instance}} :{{port}}")],
            desc="Up (green) and down (red) for every target on the two VMs: kube-state-metrics "
                 ":30931, node_exporter :9100, Traefik :30910, Vector :30598, Kubeletto core :30080. "
                 "A red bar is what rule TargetDown measures (5 minutes). When :30931 is red, every "
                 "pod and node panel on this board is stale.",
            w=12, h=7),
        timeseries(
            "kube-state-metrics scrape time",
            [(f'scrape_duration_seconds{{{D}, port="30931"}}', "{{instance}} :{{port}}")],
            desc="How long Prometheus waits for kube-state-metrics' answer (about 40 ms normally). "
                 "A climb means the API server or the pod is slow; the scrape times out at 10 "
                 "seconds and the target then goes down (TargetDown). No alert rule on the time.",
            unit="s", w=6, h=7),
        bargauge(
            "Samples per scrape vs the limit",
            [(f'scrape_samples_post_metric_relabeling{{{D}, instance=~"k3s.*"}} / 20000',
              "{{instance}} :{{port}}")],
            desc="Samples kept per scrape over service_dmz's sample_limit of 20,000 (prometheus.yml). "
                 "Over the limit the whole scrape fails and the target shows down (TargetDown): "
                 "kube-state-metrics grows with pod churn, so this is the one that can creep toward it "
                 "(about 15 % now). No alert rule on the ratio.",
            unit="percentunit", max=1, w=6, h=7, thresholds=hi_bad(0.5, 0.8)),
    ])
    return [b]
