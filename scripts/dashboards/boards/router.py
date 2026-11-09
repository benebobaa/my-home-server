"""Router and WAN: "is the hEX healthy, is the uplink fast, who is eating the ISP quota?"

Method USE (a resource: one router and one uplink). Top row = the answer, with
thresholds that are the numbers in rules/network.yml.
Alert expressions mirrored here: RouterWanLinkDown, RouterCpuHigh,
RouterMemoryHigh, RouterHot, RouterRebooted, WanQuotaPaceHigh,
WanInboundDayHigh, TenantWorkerInboundSustained.

Provenance: no upstream mixin or vendor board was consulted. Every query is
derived from the live metric names of the snmp_hex job (snmp_exporter modules
system, if_mib, hrDevice, hrStorage, mikrotik) and from rules/network.yml.

Facts the queries rely on (checked against the live Prometheus):
  * SNMP is scraped every 60 s; rate windows are $__rate_interval (>= 2 min).
  * ifOperStatus is 1 up / 2 down, so state panels use `== bool 1`.
  * mtxrHlTemperature is tenths of a degree, mtxrHlVoltage is tenths of a volt
    (mtxrGaugeUnit 3 = decivolt), sysUpTime is hundredths of a second.
  * hrStorageUsed / hrStorageSize share one allocation unit, so the ratio is exact.
  * The hEX exposes NO conntrack, firewall or NAT counters over SNMP: nothing
    here shows connection counts.
  * ether1 = WAN, ether3 = out-of-band (normally unplugged), ether5 = trunk to
    the switch, ether2 and ether4 spare (network-design.md), so "down" on
    those three is normal and no panel counts it.
"""
from lib import (
    board, stat, up_stat, timeseries, state_timeline, bargauge,
    steps, lo_bad, var_query,
)

WAN = 'job="snmp_hex", ifName="ether1"'
WAN_IN = 'ifHCInOctets{' + WAN + '}'
WAN_OUT = 'ifHCOutOctets{' + WAN + '}'
IN_RATE = 'rate(' + WAN_IN + '[$__rate_interval]) * 8'
OUT_RATE = 'rate(' + WAN_OUT + '[$__rate_interval]) * 8'

MEM = 'job="snmp_hex", hrStorageDescr="main memory"'
MEM_PCT = '100 * hrStorageUsed{' + MEM + '} / hrStorageSize{' + MEM + '}'

VLANS = 'job="snmp_hex", ifName=~"$vlan"'
VLAN_LEGEND = "{{ifAlias}} · {{ifName}}"

# The ISP line: "Home Internet 100 Mbps", throttled to about 5 Mbit/s once the
# 1500 GB monthly quota is gone. A throttled line peaks at 4.9 Mbit/s in a
# 5-minute average (observed from 2026-11-03), so 5.5 Mbit/s separates it from a
# free line, which peaks well above 10 Mbit/s on any normal day.
THROTTLE_CEILING = 5e6
THROTTLE_RED = 5.5e6
THROTTLE_ORANGE = 10e6
# The peak of the 5-minute average inbound rate, sampled every minute (a subquery).
# The 5-minute window is literal on purpose, so that the throttle tile and chart keep
# their meaning whatever time range the viewer picks ($__rate_interval would stretch
# to 10-17 minutes at 7 days and smear a 4.9 Mbit/s ceiling down). The SNMP scrape is
# 60 s, so 5 minutes is 5 samples. The panels that use these opt out of the
# rate-literal lint rule.
PEAK_24H = 'max_over_time((rate(' + WAN_IN + '[5m]) * 8)[24h:1m])'
PEAK_1H = 'max_over_time((rate(' + WAN_IN + '[5m]) * 8)[1h:1m])'


def _window(panel, window: str):
    """Pin one panel to its own relative time range (a rolling 7-day quota is
    unreadable in a 6-hour view). Grafana prints the override in the panel header."""
    panel.spec["timeFrom"] = window
    return panel


def boards():
    b = board(
        uid="homelab-net-router", title="Router and WAN", folder="Network",
        description="Is the hEX router healthy, is the WAN link up and how fast, how are the lab "
                    "VLANs loaded, and how close is the ISP quota? Open it after RouterCpuHigh, "
                    "RouterHot, RouterWanLinkDown or a WAN quota alert, and on the weekly review "
                    "to read the quota pace.",
        method="use", filename="router", time_from="now-24h",
        variables=[
            var_query("vlan", "VLAN",
                      'label_values(ifOperStatus{job="snmp_hex", ifName=~"vlan.*"}, ifName)',
                      multi=True, include_all=True),
        ],
    )

    # --- the answer ------------------------------------------------------------
    b.row("Is the router and its uplink OK?", [
        up_stat(
            "WAN link (ether1)", 'ifOperStatus{' + WAN + '} == bool 1',
            desc="Link state of ether1, the cable to the Biznet router (rule RouterWanLinkDown: "
                 "ifOperStatus is not up for 1 minute). DOWN means the whole lab has no internet. "
                 "Check the cable and the Biznet router; physical, so the operator.", w=3),
        stat(
            "CPU", 'avg by (instance) (hrProcessorLoad{job="snmp_hex"})', unit="percent",
            thresholds=steps(("green", None), ("red", 85)), legend="CPU", min=0, max=100,
            decimals=0, w=3,
            desc="Average load of the hEX's 4 cores (rule RouterCpuHigh: above 85 % for 10 "
                 "minutes). Normal is a few percent (a 24-hour average of about 2 %, peaks near 8 %). "
                 "High means a scan hitting the firewall, a log "
                 "flood or SNMP walks; the per-core chart below shows if one core is pinned."),
        stat(
            "Memory", MEM_PCT, unit="percent",
            thresholds=steps(("green", None), ("red", 90)), legend="memory", min=0, max=100,
            decimals=1, w=3,
            desc="Share of the hEX's 256 MB of RAM in use (rule RouterMemoryHigh: above 90 % for "
                 "15 minutes). Normal is about 25 %. Rising without recovering is a leak or a "
                 "huge connection table; reboot in a quiet moment after a snapshot."),
        stat(
            "Temperature", 'mtxrHlTemperature{job="snmp_hex"} / 10', unit="celsius",
            thresholds=steps(("green", None), ("red", 70)), legend="board", decimals=0, w=3,
            desc="Board temperature of the hEX (rule RouterHot: above 70 C for 15 minutes; the "
                 "raw MikroTik value is tenths of a degree, divided by 10 here). Normal is "
                 "low 40s. High is airflow: physical, so the operator."),
        stat(
            "Uptime", 'sysUpTime{job="snmp_hex"} / 100', unit="s",
            thresholds=steps(("red", None), ("green", 600)), legend="uptime", decimals=1, w=3,
            desc="Time since the hEX last booted (rule RouterRebooted, info: fires under 10 "
                 "minutes). The hEX has no battery, so a short uptime is usually a power cut; "
                 "HostOnBattery at the same time confirms it. Red only for the first 10 minutes."),
        stat(
            "Inbound peak, 24 h", PEAK_24H, unit="bps",
            thresholds=lo_bad(THROTTLE_ORANGE, THROTTLE_RED), legend="peak", decimals=1, w=3,
            lint_ok=("rate-literal",),
            desc="Highest 5-minute average of WAN inbound traffic in the last 24 hours. This is "
                 "the throttle indicator: once the 1500 GB monthly quota is gone the ISP caps the "
                 "line at about 5 Mbit/s and the peak sits flat at 4.9 Mbit/s (red, below 5.5). "
                 "A free line peaks above 10 Mbit/s on a normal day. Heuristic: a truly idle day "
                 "also reads low. No alert rule watches it, and WanInboundDayHigh cannot fire "
                 "while throttled (5 Mbit/s moves at most about 53 GB a day)."),
        stat(
            "WAN inbound, 24 h", 'increase(' + WAN_IN + '[24h])', unit="decbytes",
            thresholds=steps(("green", None), ("red", 60e9)), legend="24 h", decimals=1, w=3,
            desc="Bytes received on ether1 in the last 24 hours (rule WanInboundDayHigh: above 60 "
                 "GB for 1 hour). The plan allows about 50 GB a day on average. Red means "
                 "something is pulling hard right now: run services/kubeletto/tenant-bandwidth.sh."),
        stat(
            "WAN inbound, 7 days", 'increase(' + WAN_IN + '[7d])', unit="decbytes",
            thresholds=steps(("green", None), ("red", 350e9)), legend="7 d", decimals=0, w=3,
            desc="Bytes received on ether1 in the last 7 days (rule WanQuotaPaceHigh: above 350 GB "
                 "for 1 hour, the pace that uses up the 1500 GB plan before the renewal on the "
                 "16th). Same expression as the Overview tile."),
    ])

    # --- router health -----------------------------------------------------------
    b.row("Router health: CPU, memory, temperature, power", [
        timeseries(
            "CPU per core", 'hrProcessorLoad{job="snmp_hex"}', unit="percent", w=8, h=7,
            max=100, thresholds=steps(("green", None), ("red", 85)), threshold_style="dashed",
            legend="table", legend_calcs=("mean", "max"),
            desc="Utilisation of each of the 4 cores. The dashed line is the 85 % that RouterCpuHigh "
                 "uses, but that rule averages the cores for 10 minutes, so one pinned core with "
                 "three idle ones does not fire it. RouterOS exposes no run-queue or load "
                 "average over SNMP, so saturation is not visible here."),
        timeseries(
            "Memory used", [(MEM_PCT, "main memory")], unit="percent", w=8, h=7, max=100,
            thresholds=steps(("green", None), ("red", 90)), threshold_style="dashed",
            desc="Share of the 256 MB of RAM in use. The dashed line is the 90 % of rule "
                 "RouterMemoryHigh (15 minutes). A staircase that never comes back down is a "
                 "leak. Absolute usage is about 62 MiB."),
        timeseries(
            "Board temperature", [('mtxrHlTemperature{job="snmp_hex"} / 10', "board")],
            unit="celsius", w=8, h=7, max=100, decimals=0,
            thresholds=steps(("green", None), ("red", 70)), threshold_style="dashed",
            desc="Board temperature in degrees C (tenths in SNMP, divided by 10). The dashed line "
                 "is the 70 C of rule RouterHot (15 minutes). The hEX has no fan, so it follows "
                 "the room: a daily swing is normal, a climb toward 70 is airflow."),
        timeseries(
            "Supply voltage", [('mtxrHlVoltage{job="snmp_hex"} / 10', "input")], unit="volt",
            w=8, h=7, decimals=1,
            desc="DC input voltage of the hEX (tenths of a volt in SNMP, divided by 10). A flat "
                 "line near 12 V is a healthy adapter. Dips or drift point at the power brick or "
                 "a brown-out. No alert rule watches it."),
        timeseries(
            "Uptime and reboots", [('sysUpTime{job="snmp_hex"} / 100 / 86400', "uptime")],
            unit="d", w=8, h=7, decimals=1,
            desc="Days since boot, over 7 days. Each drop to zero is a reboot (rule RouterRebooted, "
                 "info: under 10 minutes). The hEX has no battery, so a drop with no change "
                 "window is usually a power cut."),
        timeseries(
            "Device errors and memory allocation failures",
            [('sum(rate(hrDeviceErrors{job="snmp_hex"}[$__rate_interval]))', "processor device errors"),
             ('sum(rate(hrStorageAllocationFailures{job="snmp_hex", hrStorageDescr="main memory"}'
              '[$__rate_interval]))', "memory allocation failures")],
            unit="cps", w=8, h=7,
            desc="The errors leg of USE for the router: hrDeviceErrors on the CPU cores and "
                 "failed memory allocations, per second. Both stay at 0 on a healthy hEX; any "
                 "line above 0 means the router is out of resources. No alert rule watches it."),
    ])
    _window(b.rows[-1].panels[4], "7d")

    # --- WAN link ------------------------------------------------------------------
    b.row("WAN link (ether1) and trunk (ether5)", [
        state_timeline(
            "Link state: WAN and trunk",
            [('ifOperStatus{job="snmp_hex", ifName=~"ether1|ether5"} == bool 1', "{{ifName}}")],
            w=8, h=7,
            desc="Link state of ether1 (WAN, rule RouterWanLinkDown) and ether5 (the trunk to "
                 "the switch: if it is down, every VLAN is cut off from the router). ether2 to "
                 "ether4 are spare or out-of-band and normally down, so they are not shown."),
        timeseries(
            "WAN throughput", [(IN_RATE, "inbound"), (OUT_RATE, "outbound")], unit="bps",
            w=16, h=7, legend="table", legend_calcs=("mean", "max", "lastNotNull"),
            thresholds=steps(("green", None), ("orange", THROTTLE_CEILING)),
            threshold_style="dashed",
            desc="Bit rate on ether1, in and out. The port is 100 Mbit/s and the plan is 100 Mbps, "
                 "but after the monthly quota the ISP caps the line at about 5 Mbit/s: the dashed "
                 "orange line marks that ceiling, and inbound that flattens against it is the "
                 "throttle. Inbound is what the quota counts. The router exposes no per-flow "
                 "counters, so who is pulling comes from the tenant-bandwidth script."),
        timeseries(
            "WAN errors and discards",
            [('rate(ifInErrors{' + WAN + '}[$__rate_interval])', "in errors"),
             ('rate(ifOutErrors{' + WAN + '}[$__rate_interval])', "out errors"),
             ('rate(ifInDiscards{' + WAN + '}[$__rate_interval])', "in discards"),
             ('rate(ifOutDiscards{' + WAN + '}[$__rate_interval])', "out discards")],
            unit="pps", w=12, h=7,
            desc="Packets per second the WAN port counted as errors (bad frames: cable, port, "
                 "duplex) or discards (dropped for lack of buffer or by policy). Healthy is 0 on "
                 "every line. Errors that grow point at the cable or the Biznet router port. No "
                 "alert rule watches it."),
        timeseries(
            "Negotiated link speed",
            [('ifHighSpeed{job="snmp_hex", ifName=~"ether1|ether5"}', "{{ifName}}")],
            unit="Mbits", w=12, h=7,
            desc="Speed each port negotiated: ether1 should read 100 (the Biznet router's port) "
                 "and ether5 1000. A drop to 10 or 100 on ether5 is a bad cable or port and "
                 "throttles the whole lab; a drop on ether1 caps the WAN below the plan. No alert "
                 "rule watches it."),
    ])

    # --- ISP quota -------------------------------------------------------------------
    b.row("ISP quota (1500 GB a month, throttled to about 5 Mbit/s after)", [
        _window(timeseries(
            "WAN inbound, rolling 24 h", [("increase(" + WAN_IN + "[24h])", "inbound 24 h")],
            unit="decbytes", w=12, h=8,
            thresholds=steps(("green", None), ("red", 60e9)), threshold_style="dashed",
            desc="Bytes received on ether1 in the trailing 24 hours, over 7 days. The dashed line "
                 "is the 60 GB of rule WanInboundDayHigh (1 hour); the plan averages 50 GB a day. "
                 "Once the line is throttled it cannot move more than about 53 GB a day, so this "
                 "rule goes quiet after the quota is gone: read the throttle indicator instead."),
            "7d"),
        _window(timeseries(
            "WAN inbound, rolling 7 days", [("increase(" + WAN_IN + "[7d])", "inbound 7 d")],
            unit="decbytes", w=12, h=8,
            thresholds=steps(("green", None), ("red", 350e9)), threshold_style="dashed",
            desc="Bytes received on ether1 in the trailing 7 days, over 30 days (the retention). "
                 "The dashed line is the 350 GB of rule WanQuotaPaceHigh (1 hour): a week above "
                 "it is on pace to use up the 1500 GB plan before the renewal on the 16th. "
                 "Prometheus keeps 30 days, so this is a pace, not the billing-month balance; "
                 "the real remaining quota is in the Biznet portal."),
            "30d"),
        _window(timeseries(
            "WAN inbound rate and peak (throttle ceiling)",
            [(IN_RATE, "inbound, average"), (PEAK_1H, "inbound, peak of the trailing hour")],
            unit="bps", w=12, h=8,
            thresholds=steps(("green", None), ("orange", THROTTLE_CEILING)),
            threshold_style="dashed", lint_ok=("rate-literal",),
            desc="Inbound bit rate on ether1 and its highest 5-minute average over the trailing "
                 "hour, over 7 days. The dashed orange line is the ISP's 5 Mbit/s throttle. A "
                 "peak that runs flat just under it (4.9 Mbit/s) for hours is the throttle; a "
                 "free line shows peaks of 10 to 60 Mbit/s. Feeds the 'Inbound peak, 24 h' tile."),
            "7d"),
        # The rule uses a 30-minute window on purpose (smooths a tenant pod that is woken
        # every couple of minutes). The panel mirrors the rule exactly, so the literal
        # [30m] is allowed here; the lighter line uses $__rate_interval.
        timeseries(
            "k3s-worker inbound (TenantWorkerInboundSustained)",
            [('rate(node_network_receive_bytes_total{instance="k3s-worker", device="eth0"}[30m]) * 8',
              "30 min average (the rule)"),
             ('rate(node_network_receive_bytes_total{instance="k3s-worker", device="eth0"}'
              '[$__rate_interval]) * 8', "short average")],
            unit="bps", w=12, h=8,
            thresholds=steps(("green", None), ("red", 2.5e6)), threshold_style="dashed",
            lint_ok=("rate-literal",),
            desc="Bit rate received on the Kubeletto tenant worker's eth0 (rule "
                 "TenantWorkerInboundSustained: the 30-minute average above 2.5 Mbit/s for 2 "
                 "hours, about 27 GB a day). The worker takes nearly all of the WAN inbound, so "
                 "this is the early pointer to who is eating the quota; eth0 can also carry "
                 "lab-internal traffic. Above the dashed line: run services/kubeletto/"
                 "tenant-bandwidth.sh to name the tenant."),
    ])

    # --- VLANs ---------------------------------------------------------------------------
    b.row("Lab VLANs: load per router interface", [
        timeseries(
            "VLAN traffic into the router (from the hosts)",
            [('rate(ifHCInOctets{' + VLANS + '}[$__rate_interval]) * 8', VLAN_LEGEND)],
            unit="bps", w=12, h=8, legend="table", legend_calcs=("mean", "max"),
            desc="Bit rate arriving at the router from each VLAN's hosts: 10 MGMT, 20 SERVERS, "
                 "25 DMZ (k3s), 30 LAB, 40 TRUSTED, 50 IOT/GUEST (pick VLANs with the filter at "
                 "the top). The trunk is 1 Gbit/s, so anything near 1 Gbit/s is saturation. "
                 "The router has no per-flow counters, so this says which VLAN, not which host."),
        timeseries(
            "VLAN traffic out of the router (to the hosts)",
            [('rate(ifHCOutOctets{' + VLANS + '}[$__rate_interval]) * 8', VLAN_LEGEND)],
            unit="bps", w=12, h=8, legend="table", legend_calcs=("mean", "max"),
            desc="Bit rate the router sends into each VLAN. The DMZ (25) carries the Kubeletto "
                 "tenants, so most of the WAN inbound reappears here. An idle VLAN (30, 40, 50) "
                 "sits near 0."),
        bargauge(
            "VLAN volume, last 24 h (in plus out)",
            [('sort_desc(increase(ifHCInOctets{' + VLANS + '}[24h])'
              ' + increase(ifHCOutOctets{' + VLANS + '}[24h]))', VLAN_LEGEND)],
            unit="decbytes", w=24, h=6,
            desc="Total bytes through each VLAN interface in the last 24 hours, both directions, "
                 "largest first. Use it to rank which VLAN is busy; the line charts above show "
                 "when."),
    ], collapsed=True)
    return [b]
