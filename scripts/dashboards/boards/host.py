"""Host and guest: "is this one machine OK?" Pick any host or guest from lab.yaml.

This is the per-host board docs/standards/observability.md section 3 promises (it
replaces the old Service board). Top row = the answer for the selected host, one tile per
host/guest alert (same conditions as the rules in services/monitoring/prometheus/rules/):
HostUnreachable and HttpProbeFailed (network.yml), TargetDown (meta.yml), PveGuestDown and
PveGuestNotBackedUp (cluster.yml). Below: what is firing for it, the guest's resources as
Proxmox sees them, the probes' latency, the host's own node_exporter if it has one, and
its logs.

Sources: derived from the live metric names on the lab's Prometheus and from the alert
rules above. No upstream mixin or vendor dashboard was consulted.

Facts that shaped the queries (checked against the live data):
- Every pve_* series carries instance="pve2" (the exporter's own target), never the guest's
  name. A guest is found through its id: pve_guest_info{name=...} maps name to id, and every
  other pve_* series is joined to it `on (id)`. Nodes have no pve_guest_info row; their
  series have id="node/<name>", so each pve query falls back to that.
- ALERTS rows do not carry one convention either: host alerts have instance=<name>, guest
  alerts (PveGuestNotBackedUp, PveGuestDown) have instance="pve2" plus id and name, and
  PveNodeDown has id="node/<name>". The alert count and table cover all three.
- pve_not_backed_up_info exists only for guests that are in no backup job; there is no 0.
- pve_disk_usage_bytes is 0 for the QEMU guests (no guest agent), and absent network
  counters for nodes.
- Only the Proxmox nodes, the monitoring CT and the k3s VMs (and `ai` while it runs) have a
  node_exporter; the other guests have the Proxmox view only.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, state_timeline, table, logs, var_query,
    steps, UP_DOWN, UP_DOWN_MAP,
)

I = 'instance=~"$instance"'
GUEST = 'pve_guest_info{name=~"$instance", template="0"}'
GUEST_ID = 'id=~"(lxc|qemu)/.*"'


def pve(metric: str) -> str:
    """One pve_* gauge of the selected guest, or of the selected node (id node/<name>)."""
    return (f'({metric}{{{GUEST_ID}}} * on (id) group_left () {GUEST})'
            f' or {metric}{{id=~"node/$instance"}}')


def pve_rate(metric: str) -> str:
    """Rate of a pve_* counter of the selected guest (nodes have no such counters)."""
    return (f'rate({metric}{{{GUEST_ID}}}[$__rate_interval])'
            f' * on (id) group_left () {GUEST}')


# PveGuestDown: pve_up == 0 for a guest with onboot=1. A stopped guest that is not set to
# start on boot (the on-demand `ai` VM, the archive CT) is off by design: state 2, no alert.
STATE = (
    f'(((pve_up{{{GUEST_ID}}} * on (id) group_left () {GUEST}) == 0)'
    ' and on (id) (pve_onboot_status == 0)) + 2'
    f' or (pve_up{{{GUEST_ID}}} * on (id) group_left () {GUEST})'
    ' or pve_up{id=~"node/$instance"}'
)
STATE_MAP = [{
    "type": "value",
    "options": {
        "0": {"text": "DOWN", "color": "red", "index": 0},
        "1": {"text": "UP", "color": "green", "index": 1},
        "2": {"text": "OFF", "color": "blue", "index": 2},
    },
}]

# PveGuestNotBackedUp: pve_not_backed_up_info == 1 for a guest in no backup job (the rule
# leaves the PBS guest itself out). 1 = in a job, 0 = in none, no value = not a guest / pbs.
NOT_BACKED_UP = '(pve_not_backed_up_info == 1)'
BACKUP = (
    f'(({GUEST} * 0 + 1) unless on (id) {NOT_BACKED_UP} unless on (id) pve_guest_info{{name=~"pbs.*"}})'
    f' or (({GUEST} * 0) and on (id) {NOT_BACKED_UP} unless on (id) pve_guest_info{{name=~"pbs.*"}})'
)
BACKUP_MAP = [{
    "type": "value",
    "options": {
        "0": {"text": "NO JOB", "color": "red", "index": 0},
        "1": {"text": "IN A JOB", "color": "green", "index": 1},
    },
}]

# Alerts for the selected host, in the three label conventions (see the module docstring).
ALERT_BASE = 'alertstate="firing", alertname!="Watchdog"'
ALERTS_HOST = f'ALERTS{{{ALERT_BASE}, {I}, id!~"(lxc|qemu)/.*|node/.*"}}'
ALERTS_GUEST = f'ALERTS{{{ALERT_BASE}, name=~"$instance", {GUEST_ID}}}'
ALERTS_NODE = f'ALERTS{{{ALERT_BASE}, id=~"node/$instance"}}'
URGENT = 'severity=~"critical|warning"'
URGENT_COUNT = (
    f'(count(ALERTS{{alertstate="firing", {URGENT}, {I}, id!~"(lxc|qemu)/.*|node/.*"}}) or vector(0))'
    f' + (count(ALERTS{{alertstate="firing", {URGENT}, name=~"$instance", {GUEST_ID}}}) or vector(0))'
    f' + (count(ALERTS{{alertstate="firing", {URGENT}, id=~"node/$instance"}}) or vector(0))'
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
UP_CELL = [{
    "matcher": {"id": "byName", "options": "Up"},
    "properties": [
        {"id": "mappings", "value": UP_DOWN_MAP},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
    ],
}]

# node_exporter: only the Proxmox nodes, the monitoring CT and the k3s VMs run one.
NODE_JOBS = 'job=~"node|service_dmz"'
FS = 'fstype=~"ext4|xfs|zfs|btrfs|vfat"'


def _line_at(value: float) -> dict:
    # A dashed boundary line is drawn in the colour of the step that starts there; these
    # are lines only (no areas), so green below and red at the boundary reads right.
    return steps(("green", None), ("red", value))


def boards():
    b = board(
        uid="homelab-infra-host", title="Host and guest", folder="Infrastructure",
        description="Is this one machine OK? Pick a host or guest from inventory/lab.yaml. Open it "
                    "from a HostUnreachable, HttpProbeFailed, PveGuest* or TargetDown alert: "
                    "ping, health URL, scrapes, Proxmox state, backup, resources and logs.",
        method="use", filename="host",
        variables=[var_query(
            "instance", "Host",
            'label_values(probe_success{job="blackbox_icmp", role!="internet"}, instance)')],
    )

    b.row("Is this host OK?", [
        up_stat(
            "Ping", f'probe_success{{job="blackbox_icmp", {I}}}',
            desc="ICMP echo from the monitoring CT (rule HostUnreachable: no answer for 3 "
                 "minutes; severity from the host's tier). DOWN means the host is off, "
                 "unplugged or cut off from the network: check the Proxmox state tile next.",
            w=4),
        up_stat(
            "Health URL", f'probe_success{{job="blackbox_http", {I}}}',
            desc="The host's `health:` URL from inventory/lab.yaml, probed over HTTP (rule "
                 "HttpProbeFailed: failing for 5 minutes; 2xx, or any answer for http_any). "
                 "UP with Ping UP but this DOWN means the machine is alive and the service is "
                 "not. n/a means the host has no health URL.",
            empty_ok=True, no_value="no health URL", w=4),
        up_stat(
            "Scrapes", f"min(up{{{I}}})",
            desc="Every Prometheus scrape of this host, all jobs (node_exporter, probes, the "
                 "Proxmox exporter, app /metrics): UP only when all succeed (rule TargetDown: "
                 "a scrape failing for 5 minutes). The scrape table below names the failing job.",
            w=4),
        problem_stat(
            "Alerts firing", URGENT_COUNT,
            desc="Critical and warning alerts firing for this host or guest, whichever label "
                 "they carry (host alerts by instance, guest alerts by Proxmox name, node alerts "
                 "by node id). Info alerts are in the table below but not counted. Red means "
                 "something here needs you.", w=3),
        stat(
            "Proxmox state", STATE, unit="none", thresholds=UP_DOWN, mappings=STATE_MAP,
            desc="A guest's run state from the Proxmox API (rule PveGuestDown: a guest with "
                 "onboot=1 that is not running for 5 minutes), or whether the cluster sees a "
                 "node online. OFF = stopped and not set to start on boot (the on-demand `ai` "
                 "VM, the archive CT): by design, no alert. The router and switch are not "
                 "Proxmox objects and show n/a.",
            empty_ok=True, no_value="not a guest", w=3),
        stat(
            "Backup", BACKUP, unit="none", thresholds=UP_DOWN, mappings=BACKUP_MAP,
            desc="Whether the guest is in a backup job (rule PveGuestNotBackedUp: in none for "
                 "an hour). Coverage only: a failed nightly run is not visible here, it arrives "
                 "as a Proxmox notification. The PBS guest itself is excluded by the rule and "
                 "shows n/a, like everything that is not a guest.",
            empty_ok=True, no_value="n/a", w=3),
        stat(
            "Uptime",
            f"({pve('pve_uptime_seconds')})", unit="s", color_mode="value",
            thresholds=steps(("blue", None)),
            mappings=[{"type": "value", "options": {"0": {"text": "stopped", "index": 0}}}],
            desc="Time since the guest (or node) started, from the Proxmox API. A short uptime "
                 "with no maintenance behind it is a reboot to explain; 'stopped' is a guest "
                 "that is off. The Nodes board has the node_exporter view of boots.",
            empty_ok=True, no_value="n/a", w=3),
    ])

    b.row("Firing and scraped", [
        table(
            "Alerts for this host",
            [(ALERTS_HOST, ""), (ALERTS_GUEST, ""), (ALERTS_NODE, "")],
            desc="Every alert firing for the selected host or guest, all severities (the tile "
                 "counts critical and warning only). Empty is the good state. Detail is the "
                 "systemd unit or the guest name where the alert has one. The runbook for each "
                 "is docs/runbooks/alerts.md under the alert's name.",
            columns=[("alertname", "Alert"), ("severity", "Severity"), ("name", "Detail"),
                     ("job", "Job")],
            sort_by="Severity", overrides=SEVERITY_COLORS, w=12, h=7, empty_ok=True),
        table(
            "Scrape targets",
            f"up{{{I}}}",
            desc="Every Prometheus target of this host: one row per job and port. Up is the "
                 "scrape result (rule TargetDown). A DOWN row names the job to look at: node "
                 "= node_exporter, blackbox_* = a probe of the host, pve = the Proxmox "
                 "exporter, service/service_dmz = an app's /metrics.",
            columns=[("job", "Job"), ("port", "Port"), ("service", "Service"), ("Value", "Up")],
            overrides=UP_CELL, w=12, h=7),
    ])

    b.row("Guest resources (Proxmox view)", [
        timeseries(
            "CPU",
            [(pve("pve_cpu_usage_ratio"), "CPU")],
            desc="CPU use as a share of the cores the guest is allotted (a 4-core VM at 50 % is "
                 "using 2 cores), from the Proxmox API; for a node, of all its cores. Pinned "
                 "near 100 % means the guest wants more cores than it has. For the monitoring "
                 "CT this is the real figure: its node_exporter shows pve2's CPU. No alert rule.",
            unit="percentunit", max=1, w=8, h=7, empty_ok=True),
        timeseries(
            "Memory",
            [(pve("pve_memory_usage_bytes"), "used"), (pve("pve_memory_size_bytes"), "allotted")],
            desc="Memory the guest uses and the memory it is allotted, from the Proxmox API. "
                 "For a container, used is its cgroup usage: touching the allotment means "
                 "OOM kills. For a VM, used is the QEMU process's footprint on the node, which "
                 "sits at the allotment after a few days because the guest's page cache fills "
                 "it (a k3s VM reads about 100 %): its real use is Memory available in the "
                 "node_exporter row (rule HostMemoryLow). A stopped guest reads 0 used.",
            unit="bytes", w=8, h=7, empty_ok=True),
        timeseries(
            "Disk",
            [(pve("pve_disk_usage_bytes"), "used"), (pve("pve_disk_size_bytes"), "size")],
            desc="Root disk used and its size, from the Proxmox API. Containers report it; "
                 "QEMU guests read 0 used because there is no guest agent, so use the "
                 "filesystem panel in the node_exporter row for the VMs. For a node it is "
                 "its root filesystem. No alert rule: HostFilesystemFull works from "
                 "node_exporter, not from this.",
            unit="bytes", w=8, h=7, empty_ok=True),
        timeseries(
            "Disk I/O",
            [(pve_rate("pve_disk_read_bytes_total"), "read"),
             (pve_rate("pve_disk_written_bytes_total"), "written")],
            desc="Bytes per second the guest reads from and writes to its disks, from the "
                 "Proxmox API (no data for nodes). Heavy writes by one guest show up as busy "
                 "time and latency on its node's disk: compare the Nodes board's Disk I/O "
                 "row. No alert rule.",
            unit="Bps", w=12, h=7, empty_ok=True),
        timeseries(
            "Network",
            [(pve_rate("pve_network_receive_bytes_total"), "receive"),
             (pve_rate("pve_network_transmit_bytes_total"), "transmit")],
            desc="Bytes per second the guest receives and sends on its virtual NIC, from the "
                 "Proxmox API (no data for nodes; the Nodes board has the physical NIC). "
                 "A flat zero on a running guest is a dead interface. No alert rule.",
            unit="Bps", w=12, h=7, empty_ok=True),
    ])

    b.row("Reachability", [
        timeseries(
            "Ping round-trip",
            [(f'probe_icmp_duration_seconds{{job="blackbox_icmp", phase="rtt", {I}}}', "round trip")],
            desc="Round-trip time of the ping from the monitoring CT. On the LAN it is "
                 "sub-millisecond to a few milliseconds; a rise with no load behind it is a "
                 "network or host problem. A gap is a lost ping (rule HostUnreachable fires "
                 "after 3 minutes of them).",
            unit="s", w=8, h=7),
        timeseries(
            "Health URL timing",
            [(f'probe_http_duration_seconds{{job="blackbox_http", {I}}}', "{{phase}}")],
            desc="Where the health URL's time goes: name lookup, TCP connect, TLS handshake, "
                 "server processing and transfer (the phases add up to the probe's duration). "
                 "A long processing slice is a slow service; a long connect or tls slice is "
                 "the network or the host. Empty when the host has no health URL (rule "
                 "HttpProbeFailed).",
            unit="s", stack=True, fill=40, w=8, h=7, empty_ok=True),
        state_timeline(
            "Probe results over time",
            [(f'probe_success{{job="blackbox_icmp", {I}}}', "ping"),
             (f'probe_success{{job="blackbox_http", {I}}}', "health URL")],
            desc="When each probe failed, over the selected range: green = answered, red = "
                 "failed. Ping red with health URL red is the host; only the health URL red "
                 "is the service. The alerts fire after 3 minutes (HostUnreachable) and 5 "
                 "minutes (HttpProbeFailed) of red.",
            w=8, h=7, empty_ok=True),
    ])

    b.row("The host itself (node_exporter)", [
        timeseries(
            "CPU utilisation",
            [(f'100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{{mode="idle", {NODE_JOBS}, {I}}}'
              '[$__rate_interval])))', "CPU")],
            desc="Share of CPU time not idle, averaged over the cores, from the host's own "
                 "node_exporter (iowait and steal count as busy). Empty for hosts without one: "
                 "only the Proxmox nodes, the monitoring CT and the k3s VMs have it. For the "
                 "monitoring CT this line is pve2's, not the CT's; use the CPU panel above.",
            unit="percent", max=100, w=8, h=7, empty_ok=True),
        timeseries(
            "Memory available",
            [(f'node_memory_MemAvailable_bytes{{{NODE_JOBS}, {I}}}'
              f' / node_memory_MemTotal_bytes{{{NODE_JOBS}, {I}}}', "available")],
            desc="MemAvailable / MemTotal from the host's own node_exporter. The dashed line "
                 "is the HostMemoryLow threshold (10 %, held 15 minutes). Empty for hosts "
                 "without a node_exporter.",
            unit="percentunit", max=1, w=8, h=7, empty_ok=True,
            thresholds=_line_at(0.10), threshold_style="dashed"),
        timeseries(
            "Filesystem free",
            [(f'node_filesystem_avail_bytes{{{NODE_JOBS}, {FS}, {I}}}'
              f' / node_filesystem_size_bytes{{{NODE_JOBS}, {FS}, {I}}}', "{{mountpoint}}")],
            desc="Free-space ratio of each mount from the host's own node_exporter. The "
                 "dashed line is the HostFilesystemFull threshold (15 %, held 15 minutes). "
                 "This is the disk figure for a VM, which the Proxmox view cannot give. "
                 "Empty for hosts without a node_exporter.",
            unit="percentunit", max=1, w=8, h=7, empty_ok=True,
            thresholds=_line_at(0.15), threshold_style="dashed"),
    ], collapsed=True)

    b.row("Logs", [
        logs(
            "Logs", '_stream:{_HOSTNAME="$instance"} or _stream:{hostname=~"$instance.*"}',
            desc="Recent log lines of the selected host from VictoriaLogs, newest first: the "
                 "journald host name, or a `hostname` label that starts with the name. Read it "
                 "around the time a probe or scrape went red. Nothing here for devices that do "
                 "not ship logs. Not checked by the generator's live verification.",
            h=12),
    ])

    return [b]
