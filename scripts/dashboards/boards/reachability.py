"""Reachability: "can everything reach everything, and how fast?"

Method RED (a service seen from outside: success, errors, duration of probes).
Top row = the answer, with the conditions of the alert rules in rules/network.yml.
Alert expressions mirrored here: HostUnreachable, InternetDown, HttpProbeFailed,
KubelettoPublicPathDown, DnsResolverFailing, RemoteAccessDown.

Provenance: no upstream mixin or vendor board was consulted. Every query is
derived from the live blackbox_exporter metric names (jobs blackbox_icmp,
blackbox_http, blackbox_public, blackbox_dns) and from rules/network.yml.

Facts the queries rely on (checked against the live Prometheus):
  * The two internet probes (instance internet-cloudflare = 1.1.1.1, internet-google
    = 8.8.8.8) carry role="internet" and NO tier label; hosts carry tier
    critical, standard or best-effort. blackbox_public carries role="public".
  * `ai` (on demand) is down most of the time and its RTT reads 0 when down;
    k3s-worker is the other best-effort host. HostUnreachable gives best-effort
    hosts severity info, so they never count as "down" in the top row.
  * probe_dns_lookup_time_seconds is blackbox resolving the probe TARGET's name
    (about 4 microseconds for an IP literal on every job). The resolver's own
    latency is probe_dns_duration_seconds{phase="request"}.
  * kubeletto-registry-auth answers 401 by design (an anonymous token request);
    the module counts that as success, so 401 is not an error on that probe.
  * The PBS certificates are valid for about 1000 years, so certificate days are
    clamped at 365.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, state_timeline, bargauge, table,
    steps, lo_bad, var_query,
)

ICMP_HOSTS = 'job="blackbox_icmp", role!="internet"'
INTERNET = 'job="blackbox_icmp", role="internet"'

# A state timeline of hosts: 0 down, 1 up, 2 = a best-effort host that is down.
# HostUnreachable gives best-effort hosts severity info (the `ai` VM is on demand),
# so they show blue instead of red and the board does not look broken.
HOST_STATE = (
    'probe_success{' + ICMP_HOSTS + ', tier!="best-effort", instance=~"$instance"}'
    ' or (1 + (probe_success{' + ICMP_HOSTS + ', tier="best-effort", instance=~"$instance"}'
    ' == bool 0))'
)
HOST_STATE_MAP = [{
    "type": "value",
    "options": {
        "0": {"text": "DOWN", "color": "red", "index": 0},
        "1": {"text": "UP", "color": "green", "index": 1},
        "2": {"text": "DOWN (best-effort)", "color": "blue", "index": 2},
    },
}]

CERT_DAYS = 'clamp_max((probe_ssl_earliest_cert_expiry - time()) / 86400, 365)'


def boards():
    b = board(
        uid="homelab-net-reachability", title="Reachability", folder="Network",
        description="Can everything reach everything, and how fast? Ping, health URLs, the public "
                    "Kubeletto path, the internet and the router's DNS. Open it after "
                    "HostUnreachable, HttpProbeFailed, InternetDown, DnsResolverFailing, "
                    "KubelettoPublicPathDown or RemoteAccessDown to see which probe fails and since "
                    "when.",
        method="red", filename="reachability", time_from="now-24h",
        variables=[
            var_query("instance", "Host",
                      'label_values(probe_success{job="blackbox_icmp", role!="internet"}, instance)',
                      multi=True, include_all=True),
            var_query("public", "Public probe",
                      'label_values(probe_success{job="blackbox_public"}, instance)'),
        ],
    )

    # --- the answer ----------------------------------------------------------------
    b.row("Can everything reach everything?", [
        problem_stat(
            "Critical hosts down",
            'count(probe_success{' + ICMP_HOSTS + ', tier="critical"} == 0)',
            desc="Critical-tier hosts that do not answer ping (rule HostUnreachable, severity "
                 "critical: 3 minutes). Any red is act-now. Tier comes from each host's monitoring "
                 "block in inventory/lab.yaml. Whole fleet, not filtered by the Host variable.",
            w=3),
        problem_stat(
            "Standard hosts down",
            'count(probe_success{' + ICMP_HOSTS + ', tier="standard"} == 0)',
            desc="Standard-tier hosts that do not answer ping (rule HostUnreachable, severity "
                 "warning: 3 minutes). Best-effort hosts are not counted: `ai` is an on-demand VM "
                 "that is off most of the time, which is expected, and k3s-worker is info-only.",
            warn_only=True, w=3),
        up_stat(
            "Internet",
            'max(probe_success{' + INTERNET + '})',
            desc="Ping to 1.1.1.1 or 8.8.8.8 from the monitoring CT (rule InternetDown: both fail "
                 "for 3 minutes). DOWN means the household uplink is out and Telegram cannot be "
                 "reached; the alert arrives afterwards as a record.", w=3),
        stat(
            "Admin gateways up",
            'count(probe_success{job="blackbox_icmp", instance=~"admin-gw.*"} == 1) or vector(0)',
            unit="short", thresholds=steps(("red", None), ("orange", 1), ("green", 2)),
            decimals=0, w=3,
            desc="How many of the two Tailscale subnet routers (admin-gw on pve3, admin-gw2 on "
                 "pve2) answer ping. 2 is healthy; 1 is HostUnreachable at warning (the pair "
                 "fails over); 0 is rule RemoteAccessDown (critical, 3 minutes): no remote access "
                 "to the lab at all."),
        problem_stat(
            "Health URLs failing",
            'count(probe_success{job="blackbox_http"} == 0)',
            desc="Health URLs from inventory/lab.yaml that do not answer as expected (rule "
                 "HttpProbeFailed: 5 minutes, severity from the host's tier). The host still "
                 "pings when this is red, so the service, not the machine, is the problem.", w=3),
        up_stat(
            "Kubeletto public path",
            'min(probe_success{job="blackbox_public"})',
            desc="api.kubeletto.com/healthz and the registry token endpoint, probed through the "
                 "public edge as a customer would (rule KubelettoPublicPathDown: 5 minutes). "
                 "Catches a broken DNS record, tunnel or Cloudflare setting that the in-lab "
                 "checks cannot see.", w=3),
        up_stat(
            "DNS resolver",
            'min(probe_success{job="blackbox_dns"})',
            desc="The hEX resolver (10.10.10.1) answers a lookup of a public name (rule "
                 "DnsResolverFailing: 3 minutes, critical). Red means every lab VLAN has lost "
                 "name resolution even if the internet itself is up.", w=3),
        stat(
            "Soonest certificate expiry", 'min(' + CERT_DAYS + ')', unit="d",
            thresholds=lo_bad(30, 14), decimals=0, legend="days left", w=3,
            desc="Days until the soonest TLS certificate seen by the HTTP probes expires, "
                 "management UIs and the public Kubeletto endpoints (anything beyond a year reads "
                 "365). No alert rule watches this: it is a review item. Under 30 days is worth "
                 "a look, under 14 is urgent."),
    ])

    # --- hosts: ping ------------------------------------------------------------------
    b.row("Hosts: ping", [
        state_timeline(
            "Ping state per host", [(HOST_STATE, "{{instance}}")],
            mappings=HOST_STATE_MAP, w=24, h=12,
            desc="Whether each host answers ping, over time (the HostUnreachable condition; it "
                 "fires after 3 minutes down). Green = up, red = down. Blue = a best-effort host "
                 "(`ai`, k3s-worker) that is down: `ai` is an on-demand VM, off most of the time, "
                 "so blue there is expected. A hole that spans several hosts on one node means "
                 "that node, not the hosts."),
        timeseries(
            "Ping round-trip time",
            [('probe_icmp_duration_seconds{' + ICMP_HOSTS + ', phase="rtt", instance=~"$instance"}'
              ' > 0', "{{instance}}")],
            unit="s", w=12, h=10,
            desc="Round-trip time of the ping to each host that answers. On the lab LAN this is "
                 "under 5 ms; a host that jumps to 20 ms or more has a congested or flapping "
                 "path (the switch and valkey have shown spikes of 22 to 25 ms). Down hosts are "
                 "left out (their RTT reads 0). No alert rule watches latency."),
        bargauge(
            "Availability, last 7 days",
            [('avg_over_time(probe_success{' + ICMP_HOSTS + ', tier!="best-effort", '
              'instance=~"$instance"}[7d])', "{{instance}}")],
            unit="percentunit", max=1, thresholds=lo_bad(0.999, 0.99), w=12, h=10,
            desc="Share of the last 7 days each host answered ping. Green is 99.9 % or better, "
                 "orange under 99.9 %, red under 99 % (a host down for more than 100 minutes a "
                 "week). Best-effort hosts are left out (`ai` is on demand, so it would always "
                 "read near 0 %). A guest that was stopped on purpose also lowers its bar."),
    ])
    # more decimals so that 99.99 % does not round to 100 %
    b.rows[-1].panels[2].spec["fieldConfig"]["defaults"]["decimals"] = 2

    # --- Kubeletto public path -----------------------------------------------------------
    b.row("Kubeletto public path (what customers reach)", [
        state_timeline(
            "Public probes: up or down",
            [('probe_success{job="blackbox_public"}', "{{instance}}")], w=12, h=6,
            desc="The two probes through the public edge: api.kubeletto.com/healthz and the "
                 "registry token endpoint (rule KubelettoPublicPathDown: either down for 5 "
                 "minutes). The token endpoint returns 401 to an anonymous request on purpose and "
                 "the probe counts that as up. Red means customers cannot deploy or call the API."),
        stat(
            "Public path availability, 7 days",
            [('avg_over_time(probe_success{job="blackbox_public"}[7d])', "{{instance}}")],
            unit="percentunit", thresholds=lo_bad(0.999, 0.99), decimals=2, w=12, h=6,
            desc="Share of the last 7 days each public probe answered correctly. Green is 99.9 % "
                 "or better, orange under 99.9 %, red under 99 %. The probe runs every 60 s, so "
                 "1 % is about 100 minutes. A dip here that the in-lab health URLs do not show "
                 "suggests the household uplink or Cloudflare rather than the cluster."),
        timeseries(
            "Public probe time",
            [('probe_duration_seconds{job="blackbox_public"}', "{{instance}}")],
            unit="s", w=12, h=8,
            desc="Total time of each public probe, from the monitoring CT out through the "
                 "household line and back. Duration of the customer-facing path: the median is about "
                 "0.5 s with spikes of several seconds (up to about 9 s in one day), because the "
                 "line is shared and, after the quota, throttled to about 5 Mbit/s (see the "
                 "Router and WAN board). A band that stays high for hours is the line. No alert "
                 "rule watches latency."),
        timeseries(
            "Public probe time by phase (selected probe)",
            [('probe_http_duration_seconds{job="blackbox_public", instance=~"$public"}',
              "{{phase}}")],
            unit="s", w=12, h=8, stack=True,
            desc="Where the time of the selected public probe goes: DNS resolve, TCP connect, TLS "
                 "handshake, server processing, transfer. The phases add up to the request, so "
                 "they are stacked. Pick the probe with the Public probe filter. A tall connect "
                 "or TLS band is the line or Cloudflare; a tall processing band is the origin."),
    ])

    # --- health URLs -----------------------------------------------------------------------
    b.row("Health URLs (HTTP probes)", [
        state_timeline(
            "Health URL state",
            [('probe_success{job="blackbox_http", instance=~"$instance"}', "{{instance}}")],
            w=12, h=8,
            desc="Whether each health URL from inventory/lab.yaml answered as expected (rule "
                 "HttpProbeFailed: 5 minutes; 2xx, or any answer for the management UIs that use "
                 "the http_any module). Green = answers, red = fails while the host may still "
                 "ping."),
        table(
            "HTTP status per health URL",
            ['probe_http_status_code{job="blackbox_http", instance=~"$instance"}'
             ' or probe_http_status_code{job="blackbox_public"}'],
            columns=[("instance", "Probe"), ("job", "Job"), ("Value", "HTTP status")],
            unit="none", sort_by="Probe", descending=False, w=12, h=8,
            desc="The last HTTP status code of each probe. 200 is healthy. 401 is expected on "
                 "kubeletto-registry-auth (an anonymous token request) and on the management "
                 "UIs that use the http_any module; a 5xx or 0 (no answer) is a failing service. "
                 "Read it together with the state chart, which applies each probe's own "
                 "success rule."),
        timeseries(
            "Probe time per health URL",
            [('probe_duration_seconds{job="blackbox_http", instance=~"$instance"}', "{{instance}}")],
            unit="s", w=12, h=8,
            desc="Total time of each health probe: duration of the services' front doors. Lab URLs "
                 "answer in a few ms to tens of ms; the switch UI is the slowest (about 170 ms, a "
                 "small embedded server). A sustained rise on one line is that service slowing "
                 "down. No alert rule watches latency."),
        timeseries(
            "Request time by phase (average over the selected URLs)",
            [('avg by (phase) (probe_http_duration_seconds{job="blackbox_http", '
              'instance=~"$instance"})', "{{phase}}")],
            unit="s", w=12, h=8, stack=True,
            desc="Average time of each HTTP phase across the selected health URLs: resolve, "
                 "connect, TLS, processing, transfer. The phases add up to the request, so they "
                 "are stacked; select one host to see only that host. A growing TLS band is "
                 "a slow certificate handshake, a growing processing band is a slow service."),
        bargauge(
            "Certificate days left",
            [(CERT_DAYS, "{{instance}}")],
            unit="d", max=365, thresholds=lo_bad(30, 14), w=24, h=7,
            desc="Days until the TLS certificate each probe saw expires, for every HTTPS health "
                 "URL and the public endpoints. Anything beyond a year reads 365 (the PBS "
                 "certificates run for centuries). Green over 30 days, orange under 30, red "
                 "under 14. No alert rule watches this yet, so check it on the weekly review."),
    ], collapsed=True)

    # --- internet and DNS ------------------------------------------------------------------
    b.row("Internet and DNS", [
        state_timeline(
            "Internet and DNS probes: up or down",
            [('probe_success{' + INTERNET + '}', "{{instance}}"),
             ('probe_success{job="blackbox_dns"}', "hEX DNS resolver")],
            w=12, h=6,
            desc="Ping to 1.1.1.1 (internet-cloudflare) and 8.8.8.8 (internet-google) and the "
                 "hEX resolver's lookup of a public name. InternetDown fires when both pings fail "
                 "for 3 minutes; DnsResolverFailing when the lookup fails for 3 minutes. Red "
                 "on one internet line only is that resolver, not the uplink."),
        stat(
            "Internet and DNS availability, 7 days",
            [('avg_over_time(probe_success{' + INTERNET + '}[7d])', "{{instance}}"),
             ('avg_over_time(probe_success{job="blackbox_dns"}[7d])', "hEX DNS resolver")],
            unit="percentunit", thresholds=lo_bad(0.999, 0.99), decimals=2, w=12, h=6,
            desc="Share of the last 7 days each probe answered. Green is 99.9 % or better, orange "
                 "under 99.9 %, red under 99 %. The household line is the weak link: a few "
                 "tenths of a percent below 100 (tens of minutes a week) shows an uplink blip "
                 "even when no alert fired (they need 3 minutes)."),
        timeseries(
            "Internet round-trip time",
            [('probe_icmp_duration_seconds{' + INTERNET + ', phase="rtt"} > 0', "{{instance}}")],
            unit="s", w=12, h=8,
            desc="Ping round-trip time to 1.1.1.1 and 8.8.8.8 over the household line: 15 to 30 ms "
                 "at the moment. A sustained rise while the line is busy is queueing on the "
                 "uplink (compare the WAN throughput on the Router and WAN board). A line that "
                 "is missing here is down in the state chart. No alert rule watches latency."),
        timeseries(
            "DNS lookup time (hEX resolver)",
            [('probe_dns_duration_seconds{job="blackbox_dns", phase="request"}', "query to the hEX")],
            unit="s", w=12, h=8,
            desc="How long the hEX takes to answer the probe's lookup of a public name (the "
                 "request phase): a few ms normally, with rare spikes of seconds (up to about 2 s in "
                 "one day). A sustained rise means the hEX is waiting on its upstream resolver. probe_dns_lookup_time_seconds is deliberately not used: "
                 "it times blackbox resolving the resolver's own address (microseconds), not the "
                 "resolver. Rule DnsResolverFailing fires on failure, not on slowness."),
    ], collapsed=True)
    return [b]
