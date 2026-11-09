"""Platform workloads: "are the platform's own pods running?" (RED for the platform's services,
reduced to what Prometheus has: availability and errors. There is no request rate or latency
here: Traefik's :30910 series are read by the Kubeletto board.) The platform is every
namespace except the tenants' (kl-*) and the builds (kubeletto-builds), the same selector the
K8sPlatform* rules use: platform, registry, logs, traefik, nats, cloudflared, knative-serving,
kourier-system, node-metrics, kube-system. 24 pods, one container each, at the time of writing.

Top row = the answer, one tile per rule in rules/k8s.yml (same expressions and numbers):
K8sPlatformPodNotReady, K8sPlatformPodWaiting, K8sPlatformPodRestarting, K8sLogsDropped, and
TargetDown for Vector. Below: which pods and are they ready, restarts and why, what the
platform reserves, and the Vector log shipper. K8sTenantLogsThrottled (Vector's per-tenant
throttle) is a tenant question and is mirrored on the Tenants board; the Vector row here shows
the same counter next to the other discards.

Provenance: the queries are derived from the live metric names and labels (checked against the
lab's Prometheus on 2026-11-09) and from the alert rules above. No upstream mixin or vendor
dashboard was consulted.

Facts that shaped the queries:
- "Ready vs expected" has no "expected" from the cluster: kube-state-metrics exports no
  Deployment, DaemonSet or StatefulSet series here (only the pod, node, namespace and
  networkpolicy families), so a replica that never came back is invisible. The board compares
  ready containers with the containers of every Pending or Running platform pod. Missing pods
  entirely would need those workload series.
- prometheus.yml drops kube_pod_status_{reason,ready,scheduled,qos_class},
  kube_pod_container_info, kube_pod_tolerations and kube_pod_container_resource_limits at
  ingest: nothing here may use them. There are no kubelet or cAdvisor series either (no CPU or
  memory USE per pod); requests are the only resource figure.
- kube_pod_container_status_waiting_reason exists only while a container waits. A pod stuck in
  an INIT container has phase Pending and its main containers wait with reason PodInitializing:
  K8sPlatformPodNotReady (needs phase Running) and K8sPlatformPodWaiting (a fixed reason list
  without PodInitializing) do not see that. The "Pods not Running" tile and the waiting table
  do.
- Vector: only vector_component_discarded_events_total has series (filters are
  intentional="true": build logs, probe noise). vector_component_errors_total and the
  throttle's series are born with their first increment and have none yet, and prometheus.yml
  keeps no sent/received event counters. So the board can say what is discarded and what failed,
  not how many events flow.
- Last-terminated reason "Unknown" with exit code 255 is what a node reboot or a container
  runtime restart leaves behind; Completed/0 is a clean stop (SIGTERM at shutdown).
- The windows of the restart figures (30 min, 1 h, 24 h) and of the log counters (15 min) are
  literal on purpose: they are the questions ("in the last hour"), and the first one is the
  alert's own window.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, bargauge, table, state_timeline, text,
    steps, hi_bad, ZERO_GOOD, ZERO_WARN,
)

D = 'job="service_dmz"'
# The platform: everything but tenants (kl-*) and builds, the selector of the K8sPlatform* rules.
PLAT = 'namespace!~"kl-.*|kubeletto-builds"'
TENANTS = 'namespace=~"kl-.*"'
BUILDS = 'namespace="kubeletto-builds"'
VECTOR_UP = f'up{{{D}, port="30598"}}'

# K8sNodeMemoryRequestsHigh's phase join: kube-state-metrics keeps the request series of
# Succeeded/Failed pods, only Pending|Running pods hold a reservation.
HOLDS = (f'* on (namespace, pod, uid) group_left ()'
         f' (kube_pod_status_phase{{{D}, phase=~"Pending|Running"}} == 1)')

# K8sPlatformPodNotReady, verbatim.
NOT_READY = (f'(kube_pod_container_status_ready{{{D}, {PLAT}}} == 0)'
             f' and on (namespace, pod) (kube_pod_status_phase{{{D}, phase="Running"}} == 1)')
# K8sPlatformPodWaiting, verbatim.
WAITING = (f'kube_pod_container_status_waiting_reason{{{D}, {PLAT},'
           f' reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError"}}'
           f' == 1')
# K8sPlatformPodRestarting, verbatim (the rule's window is 30 minutes).
RESTARTING = f'increase(kube_pod_container_status_restarts_total{{{D}, {PLAT}}}[30m]) > 2'
# Containers of the platform pods that are not finished: the "expected" side of ready.
EXPECTED = f'kube_pod_container_status_ready{{{D}, {PLAT}}} {HOLDS}'


def zero_unless_gone(expr: str) -> str:
    """`expr`, or 0 while kube-state-metrics answers for the platform; no data (n/a) when it does not."""
    return f'{expr} or 0 * count(kube_pod_info{{{D}, {PLAT}}})'


def by_pod(expr: str) -> str:
    """One row per platform pod, keyed (namespace, pod, node, phase), for the merged pod table.
    `expr` carries namespace, pod and uid; every query gets the same four labels so Grafana's
    merge puts them in one row."""
    return (f'max by (namespace, pod, exported_node, phase) (({expr})'
            f' * on (namespace, pod, uid) group_left (exported_node) kube_pod_info{{{D}, {PLAT}}}'
            f' * on (namespace, pod, uid) group_left (phase) (kube_pod_status_phase{{{D}, {PLAT}}} == 1))')


def by_last(expr: str) -> str:
    """One row per container that has a last-terminated record, keyed (namespace, pod, container, reason)."""
    return (f'max by (namespace, pod, container, reason) (({expr})'
            f' * on (namespace, pod, uid, container) group_left (reason)'
            f' kube_pod_container_status_last_terminated_reason{{{D}, {PLAT}}})')


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def reserved(resource: str, selector: str, by: str = "") -> str:
    """Requests of Pending|Running pods in `selector` namespaces, optionally by a label."""
    agg = f"sum by ({by})" if by else "sum"
    return (f'{agg} (kube_pod_container_resource_requests{{{D}, resource="{resource}", {selector}}} {HOLDS})')


def boards():
    b = board(
        uid="homelab-k8s-workloads", title="Platform workloads", folder="Kubernetes",
        description="Are the platform's own pods running? Kubeletto's core, registry, NATS, Traefik, "
                    "Knative, cloudflared, Vector and the system pods, never the tenants'. Open it "
                    "after a K8sPlatformPodNotReady, K8sPlatformPodWaiting, K8sPlatformPodRestarting "
                    "or K8sLogsDropped alert, or after a node reboot to see everything came back.",
        method="red", filename="workloads",
    )

    b.row("Are the platform pods running?", [
        problem_stat(
            "Containers not ready", zero_unless_gone(f'count({NOT_READY})'),
            no_value="n/a", empty_ok=False,
            desc="Platform containers whose pod is Running but whose readiness probe fails (rule "
                 "K8sPlatformPodNotReady: for 10 minutes, warning). Deploys, builds or traffic "
                 "through that component fail: the registry, NATS, cloudflared and Traefik are "
                 "the ones customers feel. Tenant (kl-*) and build pods are excluded, as in the "
                 "rule. The pod table below names the pod.", w=3),
        problem_stat(
            "Containers stuck waiting", zero_unless_gone(f'count({WAITING})'),
            no_value="n/a", empty_ok=False,
            desc="Platform containers that cannot start: CrashLoopBackOff, ImagePullBackOff, "
                 "ErrImagePull, CreateContainerConfigError or CreateContainerError (rule "
                 "K8sPlatformPodWaiting: for 10 minutes, warning). Look at the reason in the "
                 "waiting table. Not counted: a pod stuck in an init container (PodInitializing), "
                 "which the 'Pods not Running' tile shows instead.", w=3),
        problem_stat(
            "Containers restarting", zero_unless_gone(f'count({RESTARTING})'),
            no_value="n/a", empty_ok=False,
            desc="Platform containers that restarted more than twice in 30 minutes (rule "
                 "K8sPlatformPodRestarting, warning). A node reboot restarts each container once, so "
                 "more than two is a component falling over: often an out-of-memory kill or a "
                 "failing liveness probe. The 'last restart' table gives the reason.", w=3),
        problem_stat(
            "Pods not Running",
            f'count(kube_pod_status_phase{{{D}, {PLAT}, phase=~"Pending|Failed|Unknown"}} == 1)'
            f' or 0 * count(kube_pod_info{{{D}, {PLAT}}})',
            warn_only=True, no_value="n/a", empty_ok=False,
            desc="Platform pods that are Pending, Failed or Unknown. No alert rule: a pod stuck in an "
                 "init container (Pending, main containers PodInitializing) or evicted (Failed) "
                 "raises none of the three alerts. Orange for longer than a minute after a deploy "
                 "or a reboot deserves a look: the pod table shows its phase.", w=3),
        stat(
            "Containers ready", f'sum({EXPECTED}) / count({EXPECTED})', unit="percentunit", decimals=0,
            thresholds=steps(("red", None), ("green", 1)),
            desc="Ready containers over all containers of the Pending or Running platform pods: "
                 "'ready vs expected'. 100 % is every platform container serving. Expected means "
                 "the pods that exist: kube-state-metrics here exports no Deployment, DaemonSet "
                 "or StatefulSet series, so a replica that is simply missing does not lower it. "
                 "No alert rule on the ratio (K8sPlatformPodNotReady counts the unready ones).",
            w=3),
        stat(
            "Restarts, 24 hours",
            f'sum(increase(kube_pod_container_status_restarts_total{{{D}, {PLAT}}}[24h]))',
            thresholds=ZERO_WARN, decimals=0, lint_ok=("rate-literal",),
            desc="Platform container restarts in the last 24 hours, all together. Orange for a day "
                 "after a node reboot is expected (every container restarts once). No alert rule: "
                 "the alert is the 30-minute burst. Compare with the 'last restart' table for which "
                 "ones.", w=3),
        up_stat(
            "Log shippers up", f'min({VECTOR_UP})',
            desc="Vector's metrics endpoint (:30598) on k3s and k3s-worker (rule TargetDown, 5 "
                 "minutes; Vector itself is a DaemonSet that ships every tenant's and the platform's "
                 "logs to VictoriaLogs). DOWN: its metrics are stale and tenant 'kubeletto "
                 "logs' may have holes. Check the pod in the pod table.", w=3),
        problem_stat(
            "Log events lost, 15 min",
            f'sum(increase(vector_component_discarded_events_total{{{D}, intentional="false"}}[15m]))'
            f' or 0 * count({VECTOR_UP})',
            no_value="n/a", empty_ok=False, lint_ok=("rate-literal",),
            desc="Log events Vector lost to a failure (rule K8sLogsDropped: any in 15 minutes, "
                 "warning): a sink rejected or timed out, usually VictoriaLogs down or full. Filters "
                 "and the per-tenant throttle discard on purpose (intentional=\"true\") and do not "
                 "count here; the Vector row shows them. Lost lines do not come back.", w=3),
    ])

    b.row("Which pods, and are they ready?", [
        table(
            "Platform pods",
            [by_pod(f'count by (namespace, pod, uid) (kube_pod_container_status_ready{{{D}, {PLAT}}})'
                    f' - sum by (namespace, pod, uid) (kube_pod_container_status_ready{{{D}, {PLAT}}})'),
             by_pod(f'sum by (namespace, pod, uid) (kube_pod_container_status_restarts_total{{{D}, {PLAT}}})'),
             # fixed windows: "restarts in the last hour / day" is the question (see the docstring)
             by_pod(f'round(sum by (namespace, pod, uid) (increase(kube_pod_container_status_restarts_total{{{D}, {PLAT}}}[1h])))'),
             by_pod(f'round(sum by (namespace, pod, uid) (increase(kube_pod_container_status_restarts_total{{{D}, {PLAT}}}[1d])))'),
             by_pod(f'time() - max by (namespace, pod, uid) (kube_pod_start_time{{{D}, {PLAT}}})')],
            desc="Every platform pod, with the node it runs on, its phase, how many of its "
                 "containers are not ready (red above 0: K8sPlatformPodNotReady's condition), "
                 "its restart count in total, in the last hour and in the last 24 hours, and its "
                 "age. Not-ready pods sort first. k3s carries the platform; only node_exporter, "
                 "Vector and coredns run on k3s-worker. A young age means the pod was "
                 "recreated: a rollout, an eviction or a node reboot. Restarts since a pod's "
                 "birth reset when the pod is replaced.",
            columns=[("namespace", "Namespace"), ("pod", "Pod"), ("exported_node", "Node"),
                     ("phase", "Phase"), ("Value #A", "Not ready"), ("Value #B", "Restarts"),
                     ("Value #C", "Restarts 1 h"), ("Value #D", "Restarts 24 h"), ("Value #E", "Age")],
            overrides=[
                _col("Not ready", ("color", {"mode": "thresholds"}), ("thresholds", ZERO_GOOD),
                     ("custom.cellOptions", {"type": "color-background"})),
                _col("Restarts 1 h", ("color", {"mode": "thresholds"}), ("thresholds", ZERO_WARN),
                     ("custom.cellOptions", {"type": "color-text"})),
                _col("Restarts 24 h", ("color", {"mode": "thresholds"}), ("thresholds", ZERO_WARN),
                     ("custom.cellOptions", {"type": "color-text"})),
                _col("Age", ("unit", "s")),
            ],
            sort_by="Not ready", descending=True, w=24, h=11, lint_ok=("rate-literal",)),
        timeseries(
            "Containers not ready, over time",
            [(zero_unless_gone(f'count({NOT_READY})'), "not ready")],
            desc="The K8sPlatformPodNotReady condition over the dashboard's range: platform containers "
                 "whose pod is Running and not ready. A blip of a minute or two is a rollout or a "
                 "restart; the rule waits 10 minutes before it alerts. Flat at 0 is the good state.",
            unit="short", w=12, h=7),
        timeseries(
            "Platform pods by phase",
            [(f'sum by (phase) (kube_pod_status_phase{{{D}, {PLAT}}} == 1)', "{{phase}}")],
            desc="Platform pods in each phase; the phases sum to every platform pod "
                 "kube-state-metrics knows. Running is the norm (24 at the time of writing). A Pending "
                 "or Failed band that stays is a pod stuck or evicted.",
            unit="short", stack=True, w=12, h=7),
    ])

    b.row("Restarts and failures", [
        timeseries(
            "Container restarts, by namespace",
            [(f'sum by (namespace) (increase(kube_pod_container_status_restarts_total{{{D}, {PLAT}}}[$__rate_interval]))',
              "{{namespace}}")],
            desc="Platform container restarts in each window, summed per namespace, over the "
                 "dashboard's range. A bump on every namespace at once is a node reboot. One "
                 "namespace repeating is a component falling over (rule K8sPlatformPodRestarting "
                 "alerts above 2 restarts of one container in 30 minutes; the tile is per container). "
                 "A single restart can read slightly above or below 1: increase() extrapolates.",
            unit="short", w=12, h=8),
        table(
            "Last restart: reason, exit code and when",
            [by_last(f'time() - kube_pod_container_status_last_terminated_timestamp{{{D}, {PLAT}}}'),
             by_last(f'kube_pod_container_status_last_terminated_exitcode{{{D}, {PLAT}}}'),
             by_last(f'kube_pod_container_status_restarts_total{{{D}, {PLAT}}}')],
            desc="Every platform container that has restarted at least once: why its previous run "
                 "ended, the exit code, how long ago, and its restart count. Most recent first. "
                 "'Unknown' with exit code 255 is what a node reboot or a container runtime "
                 "restart leaves; 'Error' is a crash (exit code says which: 1 or 2 is the "
                 "application, 137 is SIGKILL, often out of memory); 'OOMKilled' is the memory limit; "
                 "'Completed'/0 is a clean stop such as SIGTERM at shutdown. The platform's "
                 "restarts since the last reboot are mostly 'Unknown'.",
            columns=[("namespace", "Namespace"), ("pod", "Pod"), ("container", "Container"),
                     ("reason", "Last stop"), ("Value #B", "Exit code"), ("Value #A", "Ago"),
                     ("Value #C", "Restarts")],
            overrides=[_col("Ago", ("unit", "s"))],
            sort_by="Ago", descending=False, w=12, h=8),
        table(
            "Containers waiting, any reason",
            f'kube_pod_container_status_waiting_reason{{{D}, {PLAT}}} == 1',
            desc="Every platform container that is waiting to start right now, with the reason: "
                 "CrashLoopBackOff, ImagePullBackOff and the others in rule K8sPlatformPodWaiting "
                 "(10 minutes), but also the harmless ContainerCreating and PodInitializing of a "
                 "deploy in progress. Empty is the normal state. A PodInitializing that stays "
                 "means an init container is stuck: no alert fires for it.",
            columns=[("namespace", "Namespace"), ("pod", "Pod"), ("container", "Container"),
                     ("reason", "Reason")],
            sort_by="Namespace", descending=False, w=12, h=6, empty_ok=True),
        table(
            "Init containers",
            [f'max by (namespace, pod, container) (kube_pod_init_container_status_ready{{{D}, {PLAT}}})',
             f'max by (namespace, pod, container) (kube_pod_init_container_status_restarts_total{{{D}, {PLAT}}})'],
            desc="The platform's init containers (platform-core's wait-for-deps, the registry's "
                 "config-init): whether they finished (Done = 1) and how often they "
                 "restarted. An init container that never finishes holds its pod in Pending with "
                 "the main containers waiting as PodInitializing, which no alert covers: "
                 "this table and 'Pods not Running' show it.",
            columns=[("namespace", "Namespace"), ("pod", "Pod"), ("container", "Init container"),
                     ("Value #A", "Done"), ("Value #B", "Restarts")],
            sort_by="Done", descending=False, w=12, h=6),
    ])

    b.row("What the platform reserves", [
        timeseries(
            "Memory requested, by platform namespace",
            [(reserved("memory", PLAT, "namespace"), "{{namespace}}")],
            desc="Memory requests of Running and scheduled Pending platform pods, per namespace, "
                 "stacked into the platform's total reservation. Requests are what the scheduler "
                 "counts, not what the pods use (there are no per-pod usage series). The "
                 "platform sits on the k3s server node; its total against that node's allocatable "
                 "is the fullest-node tile on the Cluster board. A step is a rollout or a "
                 "new component.",
            unit="bytes", stack=True, w=12, h=8),
        timeseries(
            "CPU requested, by platform namespace (cores)",
            [(reserved("cpu", PLAT, "namespace"), "{{namespace}}")],
            desc="CPU requests of Running and scheduled Pending platform pods, per namespace, "
                 "stacked, in cores (0.1 = 100m). Small by design: the platform is "
                 "reserved lightly so tenants keep the room. No alert rule.",
            unit="short", stack=True, decimals=2, w=12, h=8),
        bargauge(
            "Memory reserved by kind, share of the node's allocatable",
            [(f'{reserved("memory", PLAT, "exported_node")} / on (exported_node)'
              f' kube_node_status_allocatable{{{D}, resource="memory"}}',
              "{{exported_node}} platform"),
             (f'{reserved("memory", TENANTS, "exported_node")} / on (exported_node)'
              f' kube_node_status_allocatable{{{D}, resource="memory"}}',
              "{{exported_node}} tenants"),
             (f'{reserved("memory", BUILDS, "exported_node")} / on (exported_node)'
              f' kube_node_status_allocatable{{{D}, resource="memory"}}',
              "{{exported_node}} builds")],
            desc="Who holds each node's memory reservation: the platform (the pods on this board), "
                 "the tenants' apps (kl-*) and build pods, each as a share of that node's allocatable "
                 "memory. The three add up to the 'requested' ratio on the Cluster board (rules "
                 "K8sNodeMemoryRequestsHigh at 90 %, K8sNodeCapacityTrigger at 85 % for a week). The "
                 "platform lives on k3s, tenants and builds on k3s-worker. Builds are absent between "
                 "builds.",
            unit="percentunit", max=1, w=24, h=7, thresholds=hi_bad(0.85, 0.90), empty_ok=True),
    ])

    b.row("Log shipper (Vector, one per node)", [
        timeseries(
            "Events discarded on purpose, by component",
            [(f'sum by (instance, component_id) (rate(vector_component_discarded_events_total{{{D}, intentional="true"}}[$__rate_interval]))',
              "{{instance}} {{component_id}}")],
            desc="Log events per second that Vector's filters and throttle throw away deliberately "
                 "(intentional=\"true\"): build logs and probe noise are dropped by design, and "
                 "kubeletto_throttle_runtime is the per-tenant cap (6000 events per 10 s per tenant "
                 "per node; it has no series until it first drops, and then rule K8sTenantLogsThrottled "
                 "alerts: that is a tenant's runaway logger, see the Tenants board). Steady lines "
                 "are normal; a new component appearing is news.",
            unit="ops", w=8, h=8),
        timeseries(
            "Events lost to failure (K8sLogsDropped)",
            [(f'sum by (instance, component_id) (increase(vector_component_discarded_events_total{{{D}, intentional="false"}}[15m]))',
              "{{instance}} {{component_id}}"),
             ("vector(0)", "none lost")],
            desc="Log events Vector lost to a failure, over a 15-minute window, which is the window of "
                 "rule K8sLogsDropped (any above 0 alerts, warning): the VictoriaLogs sink rejected "
                 "or timed out. Flat at the 0 baseline is the good state: the counter is born "
                 "with its first lost event, so no line exists until something is lost. Lost lines "
                 "do not come back.",
            unit="short", w=8, h=8, empty_ok=True, lint_ok=("rate-literal",)),
        timeseries(
            "Vector component errors",
            [(f'sum by (instance, component_id, error_type) (increase(vector_component_errors_total{{{D}}}[$__rate_interval]))',
              "{{instance}} {{component_id}} {{error_type}}"),
             ("vector(0)", "none")],
            desc="Errors Vector's components report (decode, send, HTTP): prometheus.yml keeps this "
                 "counter, which is born with its first error, so flat at the baseline is the good "
                 "state. Errors that do not lose events (retried sends) show here without raising "
                 "K8sLogsDropped. No alert rule on the errors themselves.",
            unit="short", w=8, h=8, empty_ok=True),
        state_timeline(
            "Vector scrape targets",
            [(VECTOR_UP, "{{instance}}")],
            desc="Up (green) and down (red) for Vector's metrics endpoint on each node (rule "
                 "TargetDown, 5 minutes). Down means Vector or its NodePort is unreachable and "
                 "this row is stale.",
            w=8, h=6),
        text("What this row cannot see", (
            "**Not on this board:** how many events Vector reads and ships. prometheus.yml keeps "
            "only Vector's *discarded events*, *errors* and *started* counters (a metric allowlist: "
            "Vector exposes about 2,000 series a node), so there is no throughput, no sink latency "
            "and no queue depth. Whether lines arrive in VictoriaLogs is visible on *Observability → "
            "Log and trace stores*. Which tenant is throttled: *Kubernetes → Tenants*."),
             w=16, h=6),
    ])
    return [b]
