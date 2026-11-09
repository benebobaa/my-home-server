"""Kubeletto: "is the PaaS working for its customers?" The platform as a service, from what
Prometheus can see today. Method RED (rate, errors, duration) for the edge and the public
probes; the SLO tag is on it because a burn-rate row is added later (ADR 0036).

Top row = the answer, with the thresholds of the alert rules it mirrors:
KubelettoPublicPathDown (network.yml), HttpProbeFailed on the k3s health URL (network.yml),
KubelettoUsageMeterStale and KubelettoUsageMeterMissing, K8sPlatformPodNotReady,
K8sTenantLogsThrottled and K8sLogsDropped (k8s.yml). The rows below: the public path
(availability against the 99.5 % objective, probe time), the core and its usage meters, the
Traefik edge by service group, the log pipeline, the platform pods, and a plain statement of
what is not instrumented.

Provenance: no upstream mixin or vendor board was consulted. Every query is derived from the
live metric names (blackbox_public and blackbox_http probes; service_dmz ports 30080 core
health proxy, 30910 Traefik, 30931 kube-state-metrics, 30598 Vector) and from
rules/k8s.yml and rules/network.yml. The platform-pod queries started from the old
platform-k3s board (git 0b2d5b6) and were re-checked. The meaning of the two usage-meter
gauges is from core's handler (kubeletto-home apps/core/internal/httpapi/internal_metrics.go,
read only): started_seconds is the start of the first window the meter recorded (a constant),
processed_until_seconds is the end of the newest window.

Facts the queries rely on (checked against the live Prometheus on 2026-11-09):
  * The public probes run from the monitoring CT out through the household line, Cloudflare
    and the tunnel back in, every 60 s. A household outage reads as a Kubeletto outage, and
    a window in which the monitoring host itself was down has no probes at all.
  * Prometheus keeps 30 days; the probes cover about 25 of them (they start with the cutover).
  * Usage-meter lag is a sawtooth of 2 to 10 minutes (5-minute windows read 2 minutes after
    they close; the worst lag in 7 days was 600 s). The alert is at 1800 s.
  * Traefik's service metrics carry `exported_service` (the target's own `service` label
    clashes): traefik-api-<hash>, traefik-user-apps-<hash>, traefik-dom-<uuid>-<hash>, all
    @kubernetescrd. The duration histogram has the buckets 0.1, 0.3, 1.2, 5 and +Inf, and the
    `protocol` label (http, websocket, sse): websocket and SSE durations are connection
    lifetimes, so the latency share counts http only.
  * A client that hangs up is recorded as 499 (not in 5xx). Over the 24 hours to 2026-11-09 the
    tenant apps' route (user-apps) had all but three of the 5xx (the domains route had three
    502s), the API route had none, and about 600 of the tenant 5xx were 504s on websocket
    upgrades.
  * Vector's own series: only `intentional="true"` discards exist today (probe noise, build
    logs). The throttle series and every error series appear on the first drop or error, so
    an empty result is the good state, and the K8sLogsDropped rule has nothing to read today.
  * The in-cluster VictoriaLogs is not scraped: the vl_* series belong to the lab's own log
    store (instance logs, CT 121). Nothing in Prometheus measures the 7-day log retention.
  * No application-level series exist for Kubeletto core (its other metrics leave over OTLP,
    which nothing receives at home) or for the larasrouter app.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, state_timeline, bargauge, table, text,
    steps, lo_bad,
)

PUBLIC = 'job="blackbox_public"'
DMZ = 'job="service_dmz"'
# The rules' definition of the platform: everything except tenant apps (kl-*) and build pods.
PLATFORM = 'namespace!~"kl-.*|kubeletto-builds"'
RUNNING = f'(kube_pod_status_phase{{{DMZ}, phase="Running", {PLATFORM}}} == 1)'
READY = f'kube_pod_container_status_ready{{{DMZ}, {PLATFORM}}}'
# K8sPlatformPodNotReady's expression.
NOT_READY = f'({READY} == 0) and on (namespace, pod) {RUNNING}'

# The two usage meters' alert threshold (KubelettoUsageMeterStale): 30 minutes.
METER_STALE_S = 1800
# Healthy lag peaks at 10 minutes; above 15 is unusual but not yet the alert.
METER_NOTE_S = 900

AVAILABILITY_OBJECTIVE = 0.995  # ADR 0036: 99.5 % (the SLO window there is 30 days)

def req(extra: str = "") -> str:
    """Traefik's per-route request counter, optionally narrowed (', code=~"5.."')."""
    return f'traefik_service_requests_total{{{DMZ}{extra}}}'


FAST = f'traefik_service_request_duration_seconds_bucket{{{DMZ}, protocol="http", le="1.2"}}'
HTTP_COUNT = f'traefik_service_request_duration_seconds_count{{{DMZ}, protocol="http"}}'
FIVE_XX = ', code=~"5.."'
CANCELLED = ', code="499"'


def by_group(expr: str) -> str:
    """Add a `svc` label (api, user-apps, domains) from the route's service name. Anything
    that matches none of the three prefixes keeps the label `other`, so a fourth route would
    show up instead of vanishing."""
    out = f'label_replace({expr}, "svc", "other", "exported_service", ".*")'
    for name, rx in (("api", "traefik-api-.*"), ("user-apps", "traefik-user-apps-.*"),
                     ("domains", "traefik-dom-.*")):
        out = f'label_replace({out}, "svc", "{name}", "exported_service", "{rx}")'
    return out


def per_route(inner: str) -> str:
    """sum by (svc) over an expression that still carries exported_service."""
    return 'sum by (svc) (' + by_group(inner) + ')'


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def _line_at(value: float) -> dict:
    """A dashed boundary line is drawn in the colour of the step that starts there."""
    return steps(("green", None), ("red", value))


def _soft_range(panel, lo: float, hi: float):
    """Autoscale, but never tighter than lo..hi: a dip below `lo` still shows."""
    c = panel.spec["fieldConfig"]["defaults"]["custom"]
    c["axisSoftMin"], c["axisSoftMax"] = lo, hi
    return panel


def boards():
    b = board(
        uid="homelab-apps-kubeletto", title="Kubeletto", folder="Applications",
        description="Is Kubeletto working for its customers? The public path (availability "
                    "against 99.5 %, probe time), the core and its usage meters, the Traefik "
                    "edge by route, the log pipeline and the platform pods. Open it after "
                    "KubelettoPublicPathDown, KubelettoUsageMeter*, K8sPlatformPod*, "
                    "K8sTenantLogsThrottled or K8sLogsDropped, or on the weekly review.",
        method="red", filename="kubeletto", time_from="now-24h", extra_tags=("slo",),
    )

    # --- the answer ------------------------------------------------------------
    b.row("Is Kubeletto working for its customers?", [
        up_stat(  # KubelettoPublicPathDown
            "Public path", f'min(probe_success{{{PUBLIC}}})', w=3,
            links=[("Reachability board", "/d/homelab-net-reachability")],
            desc="api.kubeletto.com/healthz and the registry token endpoint, probed every 60 s "
                 "from the lab through the household line, Cloudflare and the tunnel (rule "
                 "KubelettoPublicPathDown: either one failing for 5 minutes). DOWN means the "
                 "console, the CLI and image pulls fail for customers. The probe crosses the "
                 "household line twice, so a line outage looks the same: Network > Reachability "
                 "and Router and WAN tell the two apart."),
        stat(
            "Availability, 24 h", f'min(avg_over_time(probe_success{{{PUBLIC}}}[24h]))',
            unit="percentunit", decimals=2, w=3,
            thresholds=steps(("red", None), ("green", AVAILABILITY_OBJECTIVE)),
            desc="Share of the last 24 hours in which the weaker of the two public probes "
                 "answered correctly. Green is at or above the 99.5 % objective (ADR 0036; its "
                 "window there is 30 days; 99.5 % of 24 hours allows about 7 minutes of "
                 "failure). No alert fires on this number: KubelettoPublicPathDown fires on "
                 "5 minutes down. Time when the monitoring host was off has no probes and "
                 "counts as neither."),
        stat(
            "Availability, 7 d", f'min(avg_over_time(probe_success{{{PUBLIC}}}[7d]))',
            unit="percentunit", decimals=2, w=3,
            thresholds=steps(("red", None), ("green", AVAILABILITY_OBJECTIVE)),
            desc="Share of the last 7 days in which the weaker of the two public probes "
                 "answered correctly. Green is at or above the 99.5 % objective (50 minutes "
                 "of failure a week; ADR 0036). The probe runs every 60 s, so 0.1 % is about "
                 "10 probes. The chart below the tiles shows the rolling value over time."),
        up_stat(  # HttpProbeFailed on instance k3s
            "Core ready", 'min(probe_success{job="blackbox_http", instance="k3s"})', w=3,
            desc="Core's /readyz through the NodePort health proxy on k3s:30080, probed from "
                 "the lab (rule HttpProbeFailed for instance k3s, standard tier: 5 minutes, "
                 "warning). DOWN means core is not ready: the API, builds and deploys fail. "
                 "Unlike the public probe this one does not cross the household line or "
                 "Cloudflare: DOWN here is the platform, DOWN only on the public path is the "
                 "line, Cloudflare, the tunnel or DNS."),
        stat(  # KubelettoUsageMeterStale / KubelettoUsageMeterMissing
            "Usage meter lag, worst",
            f'max(time() - kubeletto_usage_meter_processed_until_seconds{{{DMZ}}})',
            unit="s", w=3, no_value="no meter",
            thresholds=steps(("green", None), ("orange", METER_NOTE_S), ("red", METER_STALE_S)),
            desc="Time since the newest window the slowest usage meter (http_requests, "
                 "log_bytes) has recorded (rule KubelettoUsageMeterStale: over 30 minutes for "
                 "5 minutes). Healthy is a sawtooth of 2 to 10 minutes; orange is above 15, "
                 "unusual. While it is red, request caps and the tenants' usage page stand "
                 "still. 'no meter' means core serves no checkpoint at all, or the scrape is down "
                 "(TargetDown); one meter missing shows only as a missing row in the Usage "
                 "meters table (rule KubelettoUsageMeterMissing, 30 minutes)."),
        stat(
            "Edge 5xx share",
            '(sum(increase(' + req(FIVE_XX) + '[$__range])) or vector(0))'
            ' / sum(increase(' + req() + '[$__range]))',
            unit="percentunit", decimals=1, w=3,
            thresholds=steps(("blue", None), ("orange", 0.05), ("red", 0.20)),
            desc="Share of Traefik's responses in the selected time range that were 5xx, all "
                 "three routes together (the Edge row splits them). No alert rule watches it, "
                 "and ADR 0036 does not use it as the SLI: an upload the client cancels can "
                 "show as a 502, and 504s on websocket upgrades of tenant apps (most of the "
                 "5xx on 2026-11-09) count here. The colours (orange 5 %, red 20 %) are a "
                 "reading aid, not an objective. Read the by-route chart before concluding "
                 "anything."),
        problem_stat(  # K8sTenantLogsThrottled / K8sLogsDropped
            "Tenant log events lost",
            f'((sum(increase(vector_component_discarded_events_total{{{DMZ}, intentional="false"}}[$__range])) or vector(0))'
            f' + (sum(increase(vector_component_discarded_events_total{{{DMZ}, component_id="kubeletto_throttle_runtime"}}[$__range])) or vector(0)))'
            f' and on () (min(up{{{DMZ}, port="30598"}}) == 1)',
            empty_ok=False, no_value="n/a", w=3,
            desc="Log events Vector dropped in the selected time range because the per-tenant "
                 "cap was hit (rule K8sTenantLogsThrottled) or because a sink failed (rule "
                 "K8sLogsDropped): lines a tenant's `kubeletto logs` will never show. Zero is "
                 "the good state; the counters exist only after the first drop. n/a means a "
                 "Vector metrics endpoint is down, so a 0 would be a guess (TargetDown). The "
                 "Log pipeline row names the node and component."),
        stat(  # K8sPlatformPodNotReady
            "Platform pods ready",
            f'1 - (count(count by (namespace, pod) ({NOT_READY})) or vector(0))'
            f' / count({RUNNING})',
            unit="percentunit", decimals=1, w=3,
            thresholds=steps(("red", None), ("green", 1)),
            desc="Share of running platform pods (core, NATS, Valkey, registry, Traefik, "
                 "Kourier, Knative, cloudflared, logs, kube-system; never tenant kl-* or "
                 "build pods) whose containers are all ready (rule K8sPlatformPodNotReady: "
                 "a container running but not ready for 10 minutes). Anything under 100 % is "
                 "red at once: a rollout shows red for a minute, and only 10 minutes of it "
                 "alerts. The Platform pods row names the pod."),
    ])

    # --- the public path -------------------------------------------------------
    b.row("Can customers reach it, and how fast?", [
        state_timeline(
            "Public probes: up or down",
            [(f'probe_success{{{PUBLIC}}}', "{{instance}}")], w=12, h=6,
            desc="The two probes through the public edge over time: kubeletto-api is "
                 "api.kubeletto.com/healthz, kubeletto-registry-auth is the registry's token "
                 "endpoint (it answers 401 JSON to an anonymous request on purpose, which the "
                 "probe counts as up). Rule KubelettoPublicPathDown fires after 5 minutes of "
                 "red. Both red at once is the tunnel, Cloudflare or the line; one red is "
                 "that route."),
        _soft_range(timeseries(
            "Availability against the 99.5 % objective",
            [(f'avg_over_time(probe_success{{{PUBLIC}}}[24h])', "{{instance}} 24 h"),
             (f'avg_over_time(probe_success{{{PUBLIC}}}[7d])', "{{instance}} 7 d")],
            unit="percentunit", decimals=2, min=None, w=12, h=6,
            thresholds=_line_at(AVAILABILITY_OBJECTIVE), threshold_style="dashed",
            desc="Rolling availability of each public probe over the last 24 hours and 7 "
                 "days: the share of probes that answered correctly. The dashed red line is "
                 "the 99.5 % objective of ADR 0036 (whose window is 30 days): a line under it "
                 "is spending the budget faster than the objective allows. The 24-hour line "
                 "drops sharply in an outage and recovers a day later; the 7-day line moves "
                 "slowly. No alert fires on it. An error-budget and burn-rate row follows "
                 "this one in a later phase."), 0.99, 1),
        timeseries(
            "Public probe time",
            [(f'probe_duration_seconds{{{PUBLIC}}}', "{{instance}} total"),
             (f'probe_http_duration_seconds{{{PUBLIC}, phase="processing"}}',
              "{{instance}} server processing")],
            unit="s", w=24, h=7,
            desc="Time of each public probe, whole request and the server-processing share "
                 "(the wait for the first byte, after DNS, connect and TLS). The probe runs "
                 "from the lab, so the gap between the lines is the household line and "
                 "Cloudflare, not the platform; the server-processing line is the platform's "
                 "part plus the return path through the tunnel. The median is about half a "
                 "second with spikes of several seconds (9.5 s peak on 2026-11-09), because "
                 "the line is shared and, after the ISP quota, throttled (Router and WAN "
                 "board). A band that stays high for hours is the line. No alert rule "
                 "watches latency."),
    ])

    # --- the core and its meters ---------------------------------------------------
    b.row("Is the core ready, and is metering on time?", [
        state_timeline(
            "Core readiness and metrics endpoint",
            [('probe_success{job="blackbox_http", instance="k3s"}', "readyz probe"),
             (f'up{{{DMZ}, instance="k3s", port="30080"}}', "/metrics scrape")],
            w=8, h=7,
            desc="Core as seen through the NodePort health proxy (k3s:30080, which serves "
                 "core's /readyz and /metrics and nothing else). The readyz probe is rule "
                 "HttpProbeFailed (5 minutes) and the scrape is rule TargetDown; the usage "
                 "meters below are read from that same endpoint, so if the scrape is red "
                 "the meter panels are stale. Red on both while the public path is green is "
                 "unusual: check the proxy pod in the platform namespace."),
        timeseries(
            "Usage meter lag",
            [(f'time() - kubeletto_usage_meter_processed_until_seconds{{{DMZ}}}',
              "{{meter}}")],
            unit="s", w=8, h=7,
            thresholds=_line_at(METER_STALE_S), threshold_style="dashed",
            desc="How far behind real time each usage meter is: now minus the end of the "
                 "newest window it recorded. The meters turn access logs and tenant logs in "
                 "VictoriaLogs into 5-minute usage samples, read 2 minutes after a window "
                 "closes, so a healthy line is a sawtooth between 2 and 10 minutes. The dashed "
                 "line is KubelettoUsageMeterStale (30 minutes, held 5). A climbing line means "
                 "VictoriaLogs or Postgres is failing, or no replica holds the leader lock. "
                 "A missing line is KubelettoUsageMeterMissing."),
        table(
            "Usage meters",
            [f'time() - kubeletto_usage_meter_processed_until_seconds{{{DMZ}}}',
             f'kubeletto_usage_meter_processed_until_seconds{{{DMZ}}} * 1000',
             f'kubeletto_usage_meter_started_seconds{{{DMZ}}} * 1000'],
            desc="One row per meter: its lag now, the end of the newest window it recorded, "
                 "and the start of the first window it ever recorded (a constant: how far "
                 "back the metering, and so the usage page, reaches). Both meters should "
                 "list; a missing row is KubelettoUsageMeterMissing, a lag over 30 minutes is "
                 "KubelettoUsageMeterStale.",
            columns=[("meter", "Meter"), ("Value #A", "Lag"), ("Value #B", "Recorded up to"),
                     ("Value #C", "Metering since")],
            overrides=[_col("Lag", ("unit", "s")),
                       _col("Recorded up to", ("unit", "dateTimeAsIso")),
                       _col("Metering since", ("unit", "dateTimeAsIso"))],
            sort_by="Meter", descending=False, w=8, h=7),
    ])

    # --- the edge ---------------------------------------------------------------------
    b.row("What does the edge see? (rate, errors, duration)", [
        timeseries(
            "Request rate by route",
            [(per_route('rate(' + req() + '[$__rate_interval])'), "{{svc}}")],
            unit="reqps", decimals=2, w=8, h=8,
            desc="Requests per second answered through Traefik, by route: api is the "
                 "platform API (what the console and CLI call), user-apps is every tenant app, "
                 "domains is tenants' custom domains. Rate of the request counter, all "
                 "protocols. A cliff on api with the public path green is a routing or "
                 "Cloudflare problem; a swing on user-apps is a tenant, often one pinger. "
                 "No alert rule. The Kubernetes > Ingress board has the per-service detail."),
        timeseries(
            "5xx share by route",
            # 5xx / all, and a zero for a route that has no 5xx series at all.
            [(per_route('rate(' + req(FIVE_XX) + '[$__rate_interval])')
              + ' / ' + per_route('rate(' + req() + '[$__rate_interval])')
              + ' or (' + per_route('rate(' + req() + '[$__rate_interval])') + ' * 0)',
              "{{svc}}")],
            unit="percentunit", decimals=1, w=8, h=8,
            desc="Share of each route's responses that were 5xx. A route with no 5xx reads "
                 "0, not a gap. The api line is the platform's own error rate; user-apps "
                 "mostly reflects tenant apps (a crash loop, a cold start timing out, "
                 "websocket upgrades answered 504). Uploads cancelled by the client can show "
                 "up as 502 here, so this overstates real errors: that is why the SLI is the "
                 "probe, not this. domains carries a few requests a minute, so one failure "
                 "swings its line: read it with the rate chart. No alert rule. Details on the "
                 "Kubernetes > Ingress board."),
        timeseries(
            "Requests over 1.2 s, by route",
            [('1 - ' + per_route('rate(' + FAST + '[$__rate_interval])')
              + ' / ' + per_route('rate(' + HTTP_COUNT + '[$__rate_interval])'),
              "{{svc}}")],
            unit="percentunit", decimals=1, w=8, h=8,
            desc="Share of each route's HTTP requests that took longer than 1.2 seconds in "
                 "Traefik (the second-largest histogram bucket; the buckets are 0.1, 0.3, "
                 "1.2 and 5 s). Websocket and SSE connections are left out: their duration "
                 "is how long they stayed open. The api line is the platform; on user-apps "
                 "a share of several percent is normal (scale-from-zero cold starts and slow "
                 "tenant apps). A low-traffic route (domains) swings on a single slow "
                 "request. No alert rule."),
        timeseries(
            "5xx and client-cancelled responses, by code",
            [('sum by (code, protocol) (rate(' + req(FIVE_XX) + '[$__rate_interval]))',
              "{{code}} {{protocol}}"),
             ('sum by (code, protocol) (rate(' + req(CANCELLED) + '[$__rate_interval]))',
              "499 {{protocol}} (client hung up)")],
            unit="reqps", decimals=3, w=24, h=7, empty_ok=True,
            desc="What the 5xx and the client-cancelled (499) responses are, per second, "
                 "all routes together. 499 means the client closed the connection first: not "
                 "an error of the platform and not in the 5xx tile. 504 is a gateway timeout "
                 "from the backend (on 2026-11-09 mostly websocket upgrades of tenant apps); "
                 "500 is the backend answering with an error; 502 and 503 are a backend that "
                 "closed the connection or was not available (an upload cancelled by the "
                 "client can also surface as 502). Empty would mean none of them in the "
                 "window, the best case. No alert rule."),
    ])

    # --- the log pipeline -------------------------------------------------------------
    b.row("Do tenant logs reach the log store?", [
        timeseries(
            "Log events lost, by node and cause",
            [(f'sum by (instance) (increase(vector_component_discarded_events_total{{{DMZ}, component_id="kubeletto_throttle_runtime"}}[$__rate_interval]))',
              "{{instance}} throttled (per-tenant cap)"),
             (f'sum by (instance, component_id) (increase(vector_component_discarded_events_total{{{DMZ}, intentional="false"}}[$__rate_interval]))',
              "{{instance}} {{component_id}} failed")],
            unit="short", w=8, h=7, empty_ok=True,
            desc="Log events dropped per window: by the per-tenant cap (6000 events per 10 s "
                 "per tenant per node; rule K8sTenantLogsThrottled) and by a failed sink "
                 "(rule K8sLogsDropped). Each is a hole in a tenant's `kubeletto logs`, "
                 "which every plan may query for 7 days. Empty is the normal state: Vector "
                 "creates these counters on the first drop. The throttle names the node, "
                 "not the tenant; the tenant is in Vector's log."),
        timeseries(
            "Vector component errors",
            [(f'sum by (instance, component_id) (increase(vector_component_errors_total{{{DMZ}}}[$__rate_interval]))',
              "{{instance}} {{component_id}}")],
            unit="short", w=8, h=7, empty_ok=True,
            desc="Errors Vector reports per window, by component: a sink that cannot reach "
                 "VictoriaLogs, a transform that fails on an event. Errors are the early "
                 "sign of the loss the left-hand chart counts. No alert rule reads this "
                 "series (K8sLogsDropped reads discards). Empty is the normal state: the "
                 "counter appears on the first error."),
        timeseries(
            "Events filtered on purpose",
            [(f'sum by (component_id) (rate(vector_component_discarded_events_total{{{DMZ}, intentional="true", component_id!="kubeletto_throttle_runtime"}}[$__rate_interval]))',
              "{{component_id}}")],
            unit="ops", decimals=2, w=8, h=7,
            desc="Events per second Vector discards by design (health-probe noise, build "
                 "logs; intentional=\"true\", never errors). It is here as a liveness proxy, "
                 "the only Vector throughput series Prometheus keeps: on the k3s node the "
                 "probe noise is constant (about 18 events/s on 2026-11-09), so a flat zero "
                 "there suggests Vector stopped reading while its pod still looks ready. "
                 "No alert rule."),
        state_timeline(
            "Log pipeline up or down",
            # By container and node, not by pod: the Vector pods get a new name at every rollout.
            [(f'max by (container, exported_node) (kube_pod_container_status_ready{{{DMZ}, namespace="logs"}}'
              f' * on (namespace, pod) group_left (exported_node) kube_pod_info{{{DMZ}, namespace="logs"}})',
              "{{container}} ready on {{exported_node}}"),
             (f'up{{{DMZ}, port="30598"}}', "{{instance}} vector metrics")],
            w=24, h=7,
            desc="The pipeline's parts over time: victorialogs-0 (the store behind the "
                 "customers' 7-day `kubeletto logs` promise), one Vector pod per node, and "
                 "each Vector metrics endpoint (rule TargetDown). Pod readiness is "
                 "K8sPlatformPodNotReady's view. The retention itself cannot be measured "
                 "here: the in-cluster VictoriaLogs is not scraped (see the last row)."),
    ], collapsed=True)

    # --- the platform pods ------------------------------------------------------------
    b.row("Are the platform pods ready?", [
        bargauge(
            "Ready pods by platform namespace",
            [(f'1 - (count by (namespace) (count by (namespace, pod) ({NOT_READY})) or '
              f'(count by (namespace) ({RUNNING}) * 0)) / count by (namespace) ({RUNNING})',
              "{{namespace}}")],
            unit="percentunit", max=1, w=8, h=8, thresholds=steps(("red", None), ("green", 1)),
            desc="Share of running pods that are fully ready, in each platform namespace "
                 "(rule K8sPlatformPodNotReady). Full bars are healthy; a short bar names "
                 "the namespace: platform is core, its health proxy, Valkey and kube-state-metrics, "
                 "registry the image registry and its Docker Hub mirror, traefik the edge, "
                 "cloudflared the tunnel, logs the log pipeline."),
        # K8sPlatformPodRestarting's own window (increase over 30 minutes, more than 2): the
        # rule is defined on that fixed window, so the chart keeps it whatever range is picked.
        timeseries(
            "Platform container restarts in 30 minutes",
            [(f'max by (namespace) (increase(kube_pod_container_status_restarts_total{{{DMZ}, {PLATFORM}}}[30m]))',
              "{{namespace}}")],
            unit="short", decimals=1, w=8, h=8,
            thresholds=_line_at(2), threshold_style="dashed",
            desc="The most restarts any one platform container had in the last 30 minutes, "
                 "per namespace (rule K8sPlatformPodRestarting: more than 2; a node reboot "
                 "restarts each container once). A line above the dashed one is a "
                 "component falling over: usually a memory limit (OOM) or a failing liveness "
                 "probe. The window is the rule's, not the dashboard's."),
        table(
            "Platform containers not ready or stuck",
            [NOT_READY,
             f'kube_pod_container_status_waiting_reason{{{DMZ}, {PLATFORM}, '
             f'reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError"}} == 1'],
            columns=[("namespace", "Namespace"), ("pod", "Pod"), ("container", "Container"),
                     ("reason", "Waiting reason")],
            sort_by="Namespace", descending=False, w=8, h=8, empty_ok=True,
            desc="Every platform container that runs but is not ready (rule "
                 "K8sPlatformPodNotReady, 10 minutes) and every one that cannot start, with "
                 "the reason (rule K8sPlatformPodWaiting: crash loop, image pull, a missing "
                 "Secret or ConfigMap; 10 minutes). Empty is the good state."),
    ], collapsed=True)

    # --- what is not instrumented ---------------------------------------------------------
    b.row("What this board cannot see yet", [
        text(
            "Not instrumented",
            "**There are no application-level request, latency or error metrics for Kubeletto "
            "core or for the larasrouter app in Prometheus.** Everything above is the edge "
            "(Traefik sees every request, by route, not by customer or endpoint), synthetic "
            "probes of the public path, kube-state-metrics, Vector's own counters and core's "
            "two usage-meter gauges. This board has no larasrouter panels on purpose: none of "
            "its series reach Prometheus, and a panel built from the edge would pass for "
            "app health that nobody measures.\n\n"
            "**Planned follow-up:** instrument core and larasrouter (request rate, errors, "
            "latency histograms) and scrape them from the DMZ, then add the error-budget and "
            "burn-rate row for the 99.5 % objective. Also missing, and named in the panels "
            "that need them: the in-cluster VictoriaLogs is not scraped, so the 7-day log "
            "retention customers are promised is unmeasured, and there are no kubelet or "
            "cAdvisor series, so no per-pod CPU or memory.",
            w=24, h=7),
    ])

    return [b]
