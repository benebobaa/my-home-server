"""Overview: "is the lab OK?" The home dashboard, and the exemplar the other boards follow.

Top row = the answer (8 stats, same thresholds as the alerts they mirror).
Below: what is firing now, whether it is getting worse, and the capacity runway.
Alert expressions mirrored here (rules/): PveClusterNotQuorate, HostUnreachable,
InternetDown, KubelettoPublicPathDown, PveGuestNotBackedUp, WanQuotaPaceHigh,
WanInboundDayHigh, ThinPoolFilling / ThinPoolCritical, and the level behind
KubelettoErrorBudgetBurnFast / Medium / Slow (slo.yml: those fire on the rate, the tile
shows what is left).

The WAN inbound 7-day stat moved out of the top row (ADR 0036, decision 6 added the error
budget tile; the top row holds 8): it sits beside its own rolling chart in "Is it getting
worse?", which has the same query and the same 350 GB line.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, bargauge, table, text,
    steps, hi_bad, lo_bad,
)

WAN_IN = 'ifHCInOctets{job="snmp_hex", ifName="ether1"}'
NOT_BACKED_UP = (
    '(pve_not_backed_up_info == 1)'
    ' * on (id) group_left (name, node) pve_guest_info{template="0"}'
    ' unless on (id) pve_guest_info{name="pbs"}'
)
# ADR 0036 decision 6: the SLI is both public probes up; the budget is 1 - 99.5 %.
# The 30-day subquery runs at the probes' own 1 m step (as the rules do): at 5 m it samples
# one probe in five and read 24 % where the true figure on 2026-11-09 was 19 %.
SLI = 'min(probe_success{job="blackbox_public"})'
ERROR_BUDGET = 0.005
BUDGET_LEFT = (
    'clamp_min(100 * (1 - (1 - avg_over_time(' + SLI + '[30d:1m])) / ' + str(ERROR_BUDGET) + '), 0)'
)
FS = 'fstype=~"ext4|xfs|zfs|btrfs"'
RUNWAY = (
    'clamp_max(node_filesystem_avail_bytes{job="node", ' + FS + '}'
    ' / clamp_min(-deriv(node_filesystem_avail_bytes{job="node", ' + FS + '}[7d]), 1)'
    ' / 86400, 365)'
)

SEVERITY_COLORS = [{
    "matcher": {"id": "byName", "options": "Severity"},
    "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": {
            "critical": {"color": "red", "index": 0},
            "warning": {"color": "orange", "index": 1},
            "info": {"color": "blue", "index": 2},
        }}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ],
}]


def boards():
    b = board(
        uid="homelab-overview", title="Overview", folder="",
        description="Is the lab OK? The home board: open it first, from a Telegram alert or "
                    "on a weekly review. Green means nothing needs you; every red tile links "
                    "to the board that explains it.",
        method="overview", filename="overview", extra_tags=("slo",),
    )

    b.row("Is the lab OK?", [
        problem_stat(
            "Critical alerts", 'count(ALERTS{alertstate="firing", severity="critical"})',
            desc="Alerts firing at severity critical (Prometheus ALERTS series; Watchdog has "
                 "severity none and is not counted). Red means act now, at any hour.", w=3),
        problem_stat(
            "Warnings", 'count(ALERTS{alertstate="firing", severity="warning"})',
            desc="Alerts firing at severity warning: act today. Info alerts are only a record "
                 "and not counted.", warn_only=True, w=3),
        problem_stat(
            "Critical hosts down",
            'count(probe_success{job="blackbox_icmp", tier="critical"} == 0)',
            desc="Critical-tier hosts that do not answer ping (rule HostUnreachable). Tier comes "
                 "from each host's monitoring block in inventory/lab.yaml.", w=3),
        up_stat(
            "Internet", 'max(probe_success{job="blackbox_icmp", role="internet"})',
            desc="Ping to 1.1.1.1 or 8.8.8.8 from the monitoring CT (rule InternetDown: both "
                 "fail for 3 minutes). Telegram cannot be reached while this is down.", w=3),
        up_stat(
            "Kubeletto public API", 'min(probe_success{job="blackbox_public"})',
            desc="api.kubeletto.com/healthz and the registry token endpoint, probed through the "
                 "public edge (rule KubelettoPublicPathDown). The customer-facing path.", w=3),
        stat(  # the level behind KubelettoErrorBudgetBurnFast / Medium / Slow
            "Kubeletto error budget", BUDGET_LEFT, unit="percent", decimals=1, min=0, max=100,
            thresholds=lo_bad(50, 25), w=3,
            links=[("Kubeletto board", "/d/homelab-apps-kubeletto")],
            desc="Share of the 30-day error budget left: 100 % minus the failure share of the "
                 "last 30 days (the service counts as failed when either public probe fails) "
                 "as a share of the 0.5 % that the 99.5 % objective allows, which is 3 h 36 min "
                 "(ADR 0036). Red under 25 %, orange under 50 %, 0 % means the objective is "
                 "missed. The probes exist only since the cutover on 2026-10-14, about 25 days, "
                 "so until they have 30 days the figure is of the history that exists. No alert "
                 "fires on the level: KubelettoErrorBudgetBurnFast, Medium and Slow fire on how "
                 "fast it is being spent. The Kubeletto board's Error budget and burn rate row "
                 "has the history and the burn rates."),
        up_stat(
            "Cluster quorum", 'max(pve_cluster_info{quorate="1"}) or vector(0)',
            desc="Proxmox cluster quorum (rule PveClusterNotQuorate). Two nodes down loses it: "
                 "guests keep running, management actions lock.", w=3),
        problem_stat(
            "Guests not backed up", f"count({NOT_BACKED_UP})",
            desc="Guests in no backup job (rule PveGuestNotBackedUp). Counts only what the Proxmox "
                 "API reports; it does not prove the last backup succeeded.", w=3),
    ])

    b.row("Firing now", [
        table(
            "Alerts firing", 'ALERTS{alertstate="firing", alertname!="Watchdog"}',
            desc="Every alert firing right now except the Watchdog (always on by design). "
                 "Sorted by name; the severity colours match Telegram. The runbook for each is "
                 "docs/runbooks/alerts.md under the alert's name.",
            columns=[("alertname", "Alert"), ("severity", "Severity"),
                     ("instance", "Host"), ("job", "Job")],
            sort_by="Severity", overrides=SEVERITY_COLORS, h=7, empty_ok=True),
    ])

    b.row("Is it getting worse?", [
        timeseries(
            "Alerts firing over time", 'count by (severity) (ALERTS{alertstate="firing", alertname!="Watchdog"})',
            desc="How many alerts are firing at each severity. A staircase that only goes up "
                 "is something nobody is acting on; a spike that clears is a flap.",
            unit="short", w=10, h=7, empty_ok=True, stack=True,
            overrides=[
                {"matcher": {"id": "byName", "options": "critical"},
                 "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
                {"matcher": {"id": "byName", "options": "warning"},
                 "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}]},
                {"matcher": {"id": "byName", "options": "info"},
                 "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "blue"}}]},
            ]),
        stat(
            "WAN inbound, 7 days", f"increase({WAN_IN}[7d])", unit="decbytes",
            thresholds=steps(("green", None), ("orange", 300e9), ("red", 350e9)),
            desc="Bytes received on the WAN port in the last 7 days. The ISP caps 1500 GB a month "
                 "and throttles to 5 Mbit/s after; 350 GB a week is the pace that reaches it "
                 "(rule WanQuotaPaceHigh). The chart to the right is the same number over time.",
            w=4, h=7),
        timeseries(
            "WAN inbound, rolling 7 days", [(f"increase({WAN_IN}[7d])", "inbound 7 d")],
            desc="Bytes received in the trailing 7 days against the 350 GB pace that reaches the "
                 "ISP's 1500 GB monthly cap (dashed line, rule WanQuotaPaceHigh). The window is "
                 "7 days, so the first week after a Prometheus restart reads low.",
            unit="decbytes", w=10, h=7,
            thresholds=steps(("green", None), ("red", 350e9)), threshold_style="dashed",
            lint_ok=()),
    ])

    b.row("Capacity runway", [
        bargauge(
            "Disk runway, days until full", f"bottomk(8, {RUNWAY})",
            desc="Days until each filesystem is full if the last 7 days of change continue "
                 "(linear, capped at 365). Under 30 days is worth a plan; under 7 is urgent. "
                 "Mirrors HostFilesystemFull, which only fires at 15 % free.",
            unit="d", w=12, h=8, max=365,
            thresholds=lo_bad(30, 7)),
        timeseries(
            "Thin pool allocated", 'node_lvm_thin_pools_allocated{job="node"}',
            desc="LVM thin pool data allocated per Proxmox node. Guests freeze at 100 %. "
                 "Dashed lines are the alert thresholds: 85 % ThinPoolFilling, 92 % "
                 "ThinPoolCritical. pve3 hovers near 85 % and has flapped.",
            unit="percent", w=12, h=8, max=100,
            thresholds=hi_bad(85, 92), threshold_style="dashed", legend="list"),
    ])

    b.row("Reading guide", [
        text("Where to look next", (
            "**Triage** (after an alert): the table above names it. Network → *Reachability* "
            "for ping, HTTP and DNS; Infrastructure → *Host and guest* for one machine; "
            "Observability → *Monitoring health* if the monitoring itself looks wrong.  \n"
            "**Review** (weekly): the runway row, the WAN quota and the alert history. "
            "Use the *Homelab boards* menu at the top for every board."), h=3),
    ])
    return [b]
