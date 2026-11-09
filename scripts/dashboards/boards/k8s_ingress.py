"""Ingress (Traefik): "is the public edge serving, and how well?"

Method RED (a service: the one door every customer request walks through). Top row =
the answer. NO alert rule covers Traefik's traffic today (only TargetDown for the scrape
and the blackbox KubelettoPublicPathDown, which probes through the edge), so the colours
on the tiles are proposals, said so in each description, not mirrors of a rule.

Provenance: no upstream mixin or vendor board was consulted. Every query is derived from
the live Traefik metric names (job service_dmz, instance k3s, :30910; v3 metrics:
traefik_entrypoint_* and traefik_service_*, open connections, config reloads, TLS cert
expiry) and from rules/k8s.yml and docs/incidents/2026-11-06-slow-downlink-traefik-499.md.

Facts the queries rely on (checked against the live Prometheus, 2026-11-09):
  * Edge totals come from traefik_entrypoint_* (one entrypoint, websecure, takes all
    traffic; web, traefik and metrics carry no requests). The per-route split comes from
    traefik_service_*; its totals match the entrypoint's per code (checked over 1 and 7 days).
  * exported_service is one of three families of opaque names, folded here by label_replace:
    traefik-api-<hash> (the platform API), traefik-user-apps-<hash> (EVERY tenant app, one
    wildcard route) and traefik-dom-<uuid>-<hash> (named after a domain id, presumably
    one per custom domain). Anything else falls into "other".
  * The `code` label is the status Traefik answered. 499 (client closed the request) is its
    own code, not a 5xx. A websocket that upgraded carries code 0 (no HTTP status after the
    hijack); a websocket that did not upgrade carries the failure (404, 499, 504, ...).
  * protocol is http, sse or websocket. For sse and websocket the duration histogram
    measures how long the connection lived, so every latency panel filters protocol="http".
  * The duration histogram has only five buckets: 0.1, 0.3, 1.2, 5 s and +Inf. A quantile
    inside 1.2 to 5 s or above is interpolated and means nothing, so the board shows the
    SHARE of requests over 1.2 s and over 5 s, the requests per latency band, and the exact
    mean (sum / count), never a p95.
  * No cAdvisor or kubelet series exist; none of these panels needs them.
"""
from lib import (
    board, stat, up_stat, timeseries, table, text, steps, lo_bad,
)

D = 'job="service_dmz"'
EP = D + ', entrypoint="websecure"'
RI = '[$__rate_interval]'

# The three route families of exported_service, folded to a readable `route` label.
ROUTE_RE = "traefik-(api|user-apps|dom)-.*"


def by_route(inner: str) -> str:
    """sum by (route) of a per-service vector. api / user-apps (all tenants) / domains / other."""
    r = 'label_replace(' + inner + ', "route", "$1", "exported_service", "' + ROUTE_RE + '")'
    r = 'label_replace(' + r + ', "route", "other", "route", "")'        # no match: route is empty
    r = 'label_replace(' + r + ', "route", "domains", "route", "dom")'
    return 'sum by (route) (' + r + ')'


def entry(extra: str = "", fn: str = "requests_total") -> str:
    return 'traefik_entrypoint_' + fn + '{' + EP + (', ' + extra if extra else '') + '}'


def svc(extra: str = "", fn: str = "requests_total") -> str:
    return 'traefik_service_' + fn + '{' + D + (', ' + extra if extra else '') + '}'


def req_rate(extra: str = "") -> str:
    return 'sum(rate(' + entry(extra) + RI + '))'


def req_increase(extra: str, window: str = "1h") -> str:
    return 'sum(increase(' + entry(extra) + '[' + window + ']))'


def over_share(le: str, window: str | None = None) -> str:
    """Share of http requests slower than `le` seconds (entrypoint histogram)."""
    b = entry('protocol="http", le="' + le + '"', 'request_duration_seconds_bucket')
    c = entry('protocol="http"', 'request_duration_seconds_count')
    if window:
        return '1 - sum(increase(' + b + '[' + window + '])) / sum(increase(' + c + '[' + window + ']))'
    return '1 - sum(rate(' + b + RI + ')) / sum(rate(' + c + RI + '))'


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


OVERSTATES = ("5xx here overstates real server errors: a request the client cancelled halfway "
              "(an upload on a slow line) can surface as 499 or as 502, and Traefik counts the "
              "5xx a backend chooses to send as its own.")


def boards():
    b = board(
        uid="homelab-k8s-ingress", title="Ingress (Traefik)", folder="Kubernetes",
        description="Is the public edge serving Kubeletto's customers, and how well? Request rate "
                    "and response classes, the 5xx and client-closed (499) shares, latency as shares "
                    "over 1.2 s and 5 s (the histogram is coarse), traffic, connections, TLS expiry "
                    "and config reloads, by route and protocol. No alert rule covers Traefik traffic "
                    "yet: open it on a customer report, after KubelettoPublicPathDown, and weekly.",
        method="red", filename="ingress", time_from="now-6h",
    )

    # --- the answer ---------------------------------------------------------------------
    b.row("Is the edge serving?", [
        up_stat(  # TargetDown
            "Traefik scrape", 'up{' + D + ', port="30910"}', w=3,
            desc="Whether Prometheus can read Traefik's metrics (rule TargetDown, 5 minutes). DOWN "
                 "means this board is blind, and Traefik itself may be gone: check the traefik "
                 "pod on the k3s server and KubelettoPublicPathDown, which probes through the edge."),
        stat(
            "Requests per second", req_rate(), unit="reqps", decimals=2, legend="all requests",
            w=3, color_mode="value",
            desc="Requests the websecure entry point answers per second (every protocol; a "
                 "websocket counts once). Context, not a threshold: no alert watches the rate. "
                 "A drop to near 0 with the probes still green means customers are not reaching "
                 "the edge (Cloudflare tunnel); a sustained jump is a pinger or a scan."),
        stat(
            "5xx share, last hour",
            req_increase('code=~"5.."') + ' / ' + req_increase(''), unit="percentunit",
            thresholds=steps(("green", None), ("orange", 0.01), ("red", 0.05)), legend="5xx",
            decimals=1, w=3,
            desc="Share of the last hour's requests (all protocols) Traefik answered with 5xx. "
                 "No alert rule covers it: orange at 1 % and red at 5 % are proposals. "
                 + OVERSTATES + " At the time of writing most of it is 504, many of them websocket "
                 "handshakes to tenant apps; the panels below split it by code, protocol and route."),
        stat(
            "Client closed (499), last hour",
            req_increase('code="499"') + ' / ' + req_increase(''), unit="percentunit",
            legend="499", decimals=1, w=3, color_mode="value",
            desc="Share of the last hour's requests the client abandoned before Traefik could "
                 "answer (status 499; not a server error). Large uploads on the slow home line are "
                 "the known cause: Traefik's read timeout is 300 s since 2026-11-06 "
                 "(docs/incidents/2026-11-06-slow-downlink-traefik-499.md). No alert rule; "
                 "no colour on purpose."),
        stat(
            "Over 1.2 s, last hour", over_share("1.2", "1h"), unit="percentunit", legend="over 1.2 s",
            decimals=1, w=3, color_mode="value",
            desc="Share of the last hour's http requests that took longer than 1.2 s, the second "
                 "from last histogram bucket. Cold starts of scale-to-zero tenant apps are the main "
                 "source, so it moves with the churn on the Tenants board, not with Traefik's health. "
                 "Websocket and SSE are left out (their duration is the connection's life). No alert."),
        stat(
            "Over 5 s, last hour", over_share("5", "1h"), unit="percentunit", legend="over 5 s",
            decimals=1, w=3, color_mode="value",
            desc="Share of the last hour's http requests that took longer than 5 s, the top bucket: "
                 "slower is not resolved by this histogram. These are timeouts and cold starts "
                 "that went badly. No alert; no colour on purpose."),
        stat(
            "Connections open now", 'sum(traefik_open_connections{' + EP + '})', unit="short",
            legend="websecure", decimals=0, w=3, color_mode="value",
            desc="Connections open on the websecure entry point right now (websockets and "
                 "streams included). A staircase that never comes back down is a leak or a stuck "
                 "backend. No alert rule."),
        stat(
            "TLS certificate days left",
            'min((traefik_tls_certs_not_after{' + D + '} - time()) / 86400)', unit="d",
            thresholds=lo_bad(30, 14), legend="soonest expiry", decimals=0, w=3,
            desc="Days until the soonest of Traefik's served certificates expires (the two "
                 "Cloudflare origin certificates for *.kubeletto.app and *.kubeletto.com). They "
                 "last 15 years, so this reads thousands of days. No alert rule; red under 14 "
                 "and orange under 30 are proposals."),
    ])

    # --- what the edge answers -----------------------------------------------------------------
    b.row("What does the edge answer?", [
        timeseries(
            "Requests by response class",
            [(req_rate('code=~"2.."'), "2xx"),
             (req_rate('code=~"3.."'), "3xx"),
             (req_rate('code=~"4..", code!="499"'), "4xx (not 499)"),
             (req_rate('code="499"'), "499 client closed"),
             (req_rate('code=~"5.."'), "5xx"),
             (req_rate('code="0"'), "websocket upgraded (no status)")],
            unit="reqps", w=12, h=9, stack=True,
            desc="Requests per second by the status Traefik answered, stacked (the parts sum to all "
                 "requests). 3xx is mostly 304 Not Modified (conditional requests), the single largest status. "
                 "499 is shown apart from 4xx: it is the client leaving, not a client mistake. Code "
                 "0 is a websocket that upgraded (no HTTP status exists after the hijack). Healthy "
                 "is 5xx a thin sliver. " + OVERSTATES),
        timeseries(
            "Client closed (499) and 5xx, by status and protocol",
            [('sum by (code, protocol) (rate(' + entry('code=~"499|5.."') + RI + '))',
              "{{code}} {{protocol}}")],
            unit="reqps", w=12, h=9, empty_ok=False,
            desc="Requests per second answered 499 or 5xx, one line per status code and protocol. "
                 "499 is a client that left (not a server error). 504 is Traefik giving up on a "
                 "backend that did not answer in time: for websockets that is a handshake to a tenant "
                 "app that never came up, for http a slow or cold app. 502 is a backend that closed or "
                 "refused the connection, or an app that chose to send 502 (larasrouter did when its "
                 "LLM provider was unreachable, 2026-11-03), and it is also what some cancelled "
                 "uploads look like. " + OVERSTATES + " No alert rule covers any of these."),
    ])

    # --- by route and protocol -------------------------------------------------------------------
    b.row("Who is it serving? (route and protocol)", [
        timeseries(
            "Requests by route",
            [(by_route('rate(' + svc() + RI + ')'), "{{route}}")],
            unit="reqps", w=8, h=8, stack=True,
            desc="Requests per second to each route Traefik knows, stacked. user-apps is every "
                 "tenant app together (one wildcard route, so no per-tenant split exists here: "
                 "the Tenants board explains why), api is Kubeletto's platform API (api.kubeletto.com), "
                 "domains are the traefik-dom-* routes (named after a domain id, so presumably one "
                 "per custom domain). The hashed "
                 "service names are folded by label_replace."),
        timeseries(
            "Requests by protocol",
            [('sum by (protocol) (rate(' + entry() + RI + '))', "{{protocol}}")],
            unit="reqps", w=8, h=8, stack=True,
            desc="Requests per second by protocol: http, sse (event streams, such as an LLM "
                 "answer) and websocket (one per connection). Latency below is http only because "
                 "a stream's duration is its lifetime. A websocket line that grows with no "
                 "matching traffic is a client reconnect loop."),
        timeseries(
            "5xx share by route",
            [(by_route('rate(' + svc('code=~"5.."') + RI + ')') + ' / '
              + by_route('rate(' + svc() + RI + ')'), "{{route}}")],
            unit="percentunit", w=8, h=8,
            desc="Share of each route's requests answered 5xx (all protocols). A route with few "
                 "requests (domains) jumps on a single error: read it with the rate chart beside "
                 "it. No alert rule covers it. " + OVERSTATES),
    ])

    # --- latency --------------------------------------------------------------------------------------
    b.row("How slow? (http only; the histogram has five buckets)", [
        timeseries(
            "Share of http requests over 1.2 s and over 5 s",
            [(over_share("1.2"), "over 1.2 s"), (over_share("5"), "over 5 s")],
            unit="percentunit", w=12, h=8,
            desc="Share of http requests slower than 1.2 s and than 5 s. With buckets at 0.1, 0.3, "
                 "1.2, 5 s and +Inf, these two are the only latency numbers the histogram resolves; "
                 "a p95 above 1.2 s would be a straight line drawn between buckets, so none is "
                 "shown. Cold starts of scale-to-zero apps are the main source. Websocket and SSE "
                 "are left out: their duration is the connection's life. No alert rule."),
        timeseries(
            "Requests per latency band (http)",
            [('sum(rate(' + entry('protocol="http", le="0.1"', 'request_duration_seconds_bucket') + RI + '))',
              "up to 0.1 s"),
             ('sum(rate(' + entry('protocol="http", le="0.3"', 'request_duration_seconds_bucket') + RI + ')) - '
              'sum(rate(' + entry('protocol="http", le="0.1"', 'request_duration_seconds_bucket') + RI + '))',
              "0.1 to 0.3 s"),
             ('sum(rate(' + entry('protocol="http", le="1.2"', 'request_duration_seconds_bucket') + RI + ')) - '
              'sum(rate(' + entry('protocol="http", le="0.3"', 'request_duration_seconds_bucket') + RI + '))',
              "0.3 to 1.2 s"),
             ('sum(rate(' + entry('protocol="http", le="5"', 'request_duration_seconds_bucket') + RI + ')) - '
              'sum(rate(' + entry('protocol="http", le="1.2"', 'request_duration_seconds_bucket') + RI + '))',
              "1.2 to 5 s"),
             ('sum(rate(' + entry('protocol="http"', 'request_duration_seconds_count') + RI + ')) - '
              'sum(rate(' + entry('protocol="http", le="5"', 'request_duration_seconds_bucket') + RI + '))',
              "over 5 s")],
            unit="reqps", w=12, h=8, stack=True,
            desc="Requests per second in each latency band, stacked (the bands sum to all http "
                 "requests): the histogram as it is, without interpolation. Most requests sit in the "
                 "first band; the thin top bands are the slow ones. No alert rule."),
        timeseries(
            "Share over 1.2 s, by route (http)",
            [('1 - ' + by_route('rate(' + svc('protocol="http", le="1.2"', 'request_duration_seconds_bucket') + RI + ')')
              + ' / ' + by_route('rate(' + svc('protocol="http"', 'request_duration_seconds_count') + RI + ')'),
              "{{route}}")],
            unit="percentunit", w=12, h=8,
            desc="Share of each route's http requests that took more than 1.2 s. user-apps carries "
                 "the cold starts of tenant apps; api answers in a few milliseconds on "
                 "average at the time of writing. No alert rule."),
        timeseries(
            "Mean request duration, by route (http)",
            [(by_route('rate(' + svc('protocol="http"', 'request_duration_seconds_sum') + RI + ')')
              + ' / ' + by_route('rate(' + svc('protocol="http"', 'request_duration_seconds_count') + RI + ')'),
              "{{route}}")],
            unit="s", w=12, h=8,
            desc="Exact mean duration (sum divided by count, so not bucket-limited) of http requests "
                 "per route. The mean is dominated by the slow tail: a handful of 5 s and 60 s "
                 "timeouts lift it above what a typical request feels like. Use it for the trend; "
                 "the shares beside it say how many requests were slow."),
    ])

    # --- traffic ------------------------------------------------------------------------------------------
    b.row("Traffic and connections", [
        timeseries(
            "Edge traffic in and out",
            [('sum(rate(' + entry(fn="requests_bytes_total") + RI + ')) * 8', "from clients (request bodies)"),
             ('sum(rate(' + entry(fn="responses_bytes_total") + RI + ')) * 8', "to clients (responses)")],
            unit="bps", w=8, h=8,
            desc="Bit rate of request bodies Traefik receives and responses it sends. Everything "
                 "enters through the Cloudflare tunnel, so request bytes arrive on the home line's "
                 "download side (the ISP quota counts it) and responses leave on the upload side. "
                 "Request bodies are usually tiny next to what pods download on their own: see the "
                 "worker panel on the Tenants board."),
        timeseries(
            "Bytes to clients, by route",
            [(by_route('rate(' + svc(fn="responses_bytes_total") + RI + ')') + ' * 8', "{{route}}")],
            unit="bps", w=8, h=8, stack=True,
            desc="Response bit rate per route, stacked. user-apps (all tenant apps) is nearly all of "
                 "it; a sudden step is one tenant serving a big file or a page that is polled "
                 "hard. The per-tenant split is not available at this layer."),
        timeseries(
            "Open connections",
            [('sum(traefik_open_connections{' + EP + '})', "websecure")],
            unit="short", w=8, h=8, decimals=0,
            desc="Connections open on the websecure entry point over time (websockets and streams "
                 "included). Steady is healthy; a staircase that never falls back is a leak or "
                 "clients that do not hang up. A drop to 0 and a jump back is a Traefik restart. "
                 "No alert rule."),
    ])

    # --- TLS and configuration ------------------------------------------------------------------------------
    b.row("TLS and configuration", [
        table(
            "TLS certificates served",
            '(traefik_tls_certs_not_after{' + D + '} - time()) / 86400',
            columns=[("sans", "Covers"), ("cn", "Issuer name"), ("Value", "Days left")],
            overrides=[_col("Days left", ("decimals", 0), ("unit", "d"),
                            ("custom.cellOptions", {"type": "color-background"}),
                            ("color", {"mode": "thresholds"}),
                            ("thresholds", lo_bad(30, 14)))],
            sort_by="Days left", descending=False, w=10, h=7,
            desc="Every certificate Traefik serves and the days left on it, soonest first. Both are "
                 "Cloudflare origin certificates (15-year validity), so days are in the thousands. "
                 "Red under 14 and orange under 30 are proposals: no alert rule watches expiry. "
                 "The secrets are traefik/kubeletto-app-tls and kubeletto-com-tls (Kubeletto repo, "
                 "infra/k8s/home)."),
        timeseries(
            "Config reloads per hour",
            [('increase(traefik_config_reloads_total{' + D + '}[1h])', "reloads in the trailing hour")],
            unit="short", w=7, h=7, decimals=0,
            desc="Times Traefik reloaded its dynamic configuration in the trailing hour. A reload "
                 "usually follows a change to an IngressRoute, Service or Secret, so bursts line up "
                 "with platform deploys. A new Traefik pod answered its first second with 502s while "
                 "its routes loaded (2026-11-06 incident), so a burst can show as a blip in the "
                 "5xx lines. No reload-failure counter is exported today, so a failed reload shows only "
                 "as the age in the next panel growing. No alert rule."),
        timeseries(
            "Traefik uptime and age of the last config load",
            [('time() - process_start_time_seconds{' + D + ', port="30910"}', "process uptime"),
             ('time() - traefik_config_last_reload_success{' + D + '}', "since last successful reload")],
            unit="s", w=7, h=7,
            desc="Seconds since the Traefik process started (a drop to 0 is a restart or "
                 "rollout) and since its configuration last loaded successfully (a sawtooth: it "
                 "resets at each reload). An age that keeps growing while the platform is being "
                 "changed means reloads are failing. No alert rule."),
    ], collapsed=True)

    # --- reading guide ------------------------------------------------------------------------------------------
    b.row("What this board does not tell you", [
        text("Reading guide", (
            "**No alert rule covers Traefik's traffic.** Only `TargetDown` (the scrape) and "
            "`KubelettoPublicPathDown` (a blackbox probe through the edge) exist; the colours on "
            "the top tiles are proposals. **5xx overstates real server errors:** cancelled uploads "
            "can surface as 499 or 502 (shown apart), and 504 is Traefik giving up, mostly on "
            "tenant apps that were asleep. **Latency is coarse:** five buckets (0.1, 0.3, 1.2, 5 s), "
            "so only the shares over 1.2 s and 5 s are exact; http only. **No per-tenant split:** "
            "one wildcard route serves every tenant app (see the Tenants board). No cAdvisor or "
            "kubelet series exist yet."), w=24, h=5),
    ])
    return [b]
