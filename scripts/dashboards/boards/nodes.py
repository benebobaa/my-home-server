"""Nodes: "are the machines themselves OK?" USE per resource for the Proxmox nodes
(pve1, pve2, pve3), the monitoring CT and the k3s VMs: everything with a node_exporter
(job node, and job service_dmz on :9100).

Top row = the answer, one tile per host alert (same thresholds as the rules, in
services/monitoring/prometheus/rules/): TargetDown (meta.yml), HostCpuHot,
HostMemoryLow, HostFilesystemFull, HostSystemdUnitFailed, HostClockUnsynced,
HostRebooted, HostTextfileCollectorStale (hosts.yml). Below, one row per resource:
CPU, memory, disk I/O, filesystems, network (each utilisation, saturation, errors),
then the clock and the failed units.

Sources: the queries are derived from the live metric names on the lab's Prometheus
and from the alert rules above. No upstream mixin or vendor dashboard was consulted.

Facts that shaped the queries (checked against the live data):
- node_systemd_* exists only for job node; the k3s VMs do not run that collector.
- The monitoring CT cannot see its own CPU time, load average or block devices: those
  series are pve2's (its idle time equals pve2's cpu0 to three digits, its load5 equals
  pve2's, its sdb is pve2's sdb), so they read as the host, not as CT 120. Memory and
  network are the CT's own. The Host and guest board has the CT's real CPU (pve exporter).
- node_network_speed_bytes is -125000 on the VMs (virtio), so no link-utilisation panel.
- The CPU temperature expression is the one HostCpuHot uses (coretemp, k10temp by chip
  name; NVMe and ACPI sensors share node_hwmon_temp_celsius and must not count).
"""
from lib import (
    board, stat, up_stat, timeseries, bargauge, table, var_query,
    steps, lo_bad, ZERO_GOOD,
)

# --- selectors -----------------------------------------------------------------
I = 'instance=~"$instance"'
NODE_JOBS = 'job=~"node|service_dmz"'
# service_dmz also carries the k3s apps' own ports: node_exporter is :9100 only.
NODE_UP = (f'(up{{job="node", {I}}} or up{{job="service_dmz", port="9100", {I}}})')
# Physical interfaces only: the bridges, veth pairs, tap devices and CNI links
# carry the same bytes again.
NIC = 'device=~"nic[0-9]+|eth[0-9]+|en[a-z0-9]+"'
# Whole block devices: dm-*, loop and sr* would double-count or never move.
DISK = 'device=~"sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+"'
# HostFilesystemFull's filter; inodes are not reported on vfat.
FS = 'fstype=~"ext4|xfs|zfs|btrfs|vfat"'
FS_INODES = 'fstype=~"ext4|xfs|zfs|btrfs"'

CPU_COUNT = f'count by (instance) (node_cpu_seconds_total{{mode="idle", {I}}})'
MEM_AVAIL = (f'node_memory_MemAvailable_bytes{{{NODE_JOBS}, {I}}}'
             f' / node_memory_MemTotal_bytes{{{NODE_JOBS}, {I}}}')
FS_FREE = (f'node_filesystem_avail_bytes{{{NODE_JOBS}, {FS}, {I}}}'
           f' / node_filesystem_size_bytes{{{NODE_JOBS}, {FS}, {I}}}')
FS_INODES_FREE = (f'node_filesystem_files_free{{{NODE_JOBS}, {FS_INODES}, {I}}}'
                  f' / node_filesystem_files{{{NODE_JOBS}, {FS_INODES}, {I}}}')
# The same linear extrapolation as the Overview's runway panel: free bytes over the
# 7-day slope, capped at a year; a filesystem that is not shrinking reads 365.
RUNWAY = (
    f'clamp_max(node_filesystem_avail_bytes{{{NODE_JOBS}, {FS_INODES}, {I}}}'
    f' / clamp_min(-deriv(node_filesystem_avail_bytes{{{NODE_JOBS}, {FS_INODES}, {I}}}[7d]), 1)'
    ' / 86400, 365)'
)
# HostCpuHot's expression, narrowed to the selected hosts.
CPU_TEMP = (
    f'max by (instance) (node_hwmon_temp_celsius{{job="node", instance=~"pve.*", {I}}}'
    ' * on (instance, chip) group_left ()'
    ' (node_hwmon_chip_names{job="node", chip_name=~"coretemp|k10temp"} * 0 + 1))'
)

# A dashed boundary line on a time series is drawn in the colour of the step that starts
# there. These are lines only (no areas), so green below and red at the boundary reads right.
def _line_at(value: float) -> dict:
    return steps(("green", None), ("red", value))


def boards():
    b = board(
        uid="homelab-infra-nodes", title="Nodes", folder="Infrastructure",
        description="Are the machines themselves OK? Open it after a Host* or Thin pool alert, "
                    "or on a weekly review: CPU, memory, disk, filesystem and network of the "
                    "Proxmox nodes, the monitoring CT and the k3s VMs.",
        method="use", filename="nodes",
        variables=[var_query("instance", "Host", "label_values(node_uname_info, instance)",
                             multi=True, include_all=True)],
    )

    b.row("Are the machines OK?", [
        up_stat(
            "Node exporters up", f"min({NODE_UP})",
            desc="node_exporter scrapes of the selected hosts (rule TargetDown, which covers every "
                 "job). DOWN means the tiles beside this one are stale: look at Network > "
                 "Reachability for the host.", w=3),
        stat(
            "CPU temperature, hottest",
            f"max({CPU_TEMP})", unit="celsius", graph=True,
            thresholds=steps(("green", None), ("red", 90)),
            desc="Hottest CPU package among the selected Proxmox nodes (rule HostCpuHot: above "
                 "90 C for 10 minutes). Only the three nodes have a CPU sensor; the VMs show n/a. "
                 "pve1's 20-minute GPU + CPU soak peaked at 89 C.",
            empty_ok=True, w=3),
        stat(
            "Memory available, lowest", f"min({MEM_AVAIL})", unit="percentunit",
            thresholds=steps(("red", None), ("green", 0.10)),
            desc="Lowest MemAvailable / MemTotal among the selected hosts (rule HostMemoryLow: "
                 "under 10 % for 15 minutes, nodes and k3s VMs). On the k3s VMs this is the "
                 "warning before the kubelet evicts tenant pods.", w=3),
        stat(
            "Filesystem free, lowest", f"min({FS_FREE})", unit="percentunit",
            thresholds=steps(("red", None), ("green", 0.15)),
            desc="Lowest free-space ratio over every ext4, xfs, zfs, btrfs and vfat mount "
                 "of the selected hosts (rule HostFilesystemFull: under 15 % for 15 minutes). "
                 "The Filesystems row names the mount and shows the runway.", w=3),
        stat(
            "Failed systemd units",
            f'sum(node_systemd_units{{job="node", state="failed", {I}}})',
            thresholds=ZERO_GOOD, empty_ok=True,
            desc="Units in the failed state on the selected hosts (rule HostSystemdUnitFailed, "
                 "10 minutes). The k3s VMs do not export systemd state and show n/a. The table "
                 "in the last row names the unit.", w=3),
        stat(
            "Clocks not synchronised", f"sum(1 - node_timex_sync_status{{{I}}})",
            thresholds=ZERO_GOOD,
            desc="Hosts whose kernel clock is not NTP-synchronised (rule HostClockUnsynced, "
                 "15 minutes, Proxmox nodes). Corosync, TLS and log timestamps all suffer. "
                 "The rule covers the nodes; this tile counts the VMs too.", w=3),
        stat(
            "Shortest uptime", f"min(time() - node_boot_time_seconds{{{I}}})", unit="s",
            thresholds=steps(("orange", None), ("green", 900)),
            desc="Time since the most recently booted selected host started (rule HostRebooted: "
                 "a node booted in the last 15 minutes, info only). Orange means a reboot just "
                 "happened: expected after maintenance or a power cut, otherwise find out why.",
            w=3),
        stat(
            "Collector files, oldest",
            f'max(time() - node_textfile_mtime_seconds{{job="node", file=~".*/(smartmon|lvm)[.]prom", {I}}})',
            unit="s", thresholds=steps(("green", None), ("red", 3600)),
            desc="Age of the SMART and thin-pool textfile collectors' output (rule "
                 "HostTextfileCollectorStale: over 1 hour). When these stop, the disk and "
                 "thin-pool alerts are blind. Only the Proxmox nodes run them.",
            empty_ok=True, w=3),
    ])

    b.row("CPU", [
        timeseries(
            "CPU utilisation",
            [(f'100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{{mode="idle", {I}}}[$__rate_interval])))',
              "{{instance}}")],
            desc="Share of CPU time not idle, averaged over the cores of each host (iowait and "
                 "steal count as busy). Sustained near 100 means the host is CPU-bound; read it "
                 "together with load per core and CPU pressure. The monitoring CT's line is "
                 "pve2's, not the CT's own. No alert rule: the thermal alert is HostCpuHot, "
                 "in the top row.",
            unit="percent", max=100, w=8, h=7),
        timeseries(
            "Load per core",
            [(f"node_load1{{{I}}} / on (instance) {CPU_COUNT}", "{{instance}}")],
            desc="One-minute load average divided by the core count. Above 1 means more runnable "
                 "or disk-waiting tasks than cores (dashed line). Brief spikes are normal; "
                 "sustained above 2 is queueing. The monitoring CT reports pve2's load average, "
                 "divided by the CT's own 2 cores, so its line reads about twice pve2's: ignore "
                 "it. No alert rule.",
            unit="short", decimals=2, w=8, h=7,
            thresholds=_line_at(1), threshold_style="dashed"),
        timeseries(
            "CPU pressure (PSI)",
            [(f"rate(node_pressure_cpu_waiting_seconds_total{{{I}}}[$__rate_interval])", "{{instance}}")],
            desc="Share of time in which at least one task was ready to run but had no CPU "
                 "(kernel pressure stall information, 'some'). The direct saturation signal: "
                 "a few percent is normal, tens of percent sustained is contention. No alert rule.",
            unit="percentunit", max=1, w=8, h=7),
    ])

    b.row("Memory", [
        timeseries(
            "Memory available",
            [(MEM_AVAIL, "{{instance}}")],
            desc="MemAvailable / MemTotal per host. The dashed line is the HostMemoryLow "
                 "threshold (10 %, held 15 minutes). Falling toward it on a k3s VM means tenant "
                 "pods are about to be evicted; on a node, a guest has grown.",
            unit="percentunit", max=1, w=12, h=7,
            thresholds=_line_at(0.10), threshold_style="dashed"),
        timeseries(
            "Swap in use",
            [(f"node_memory_SwapTotal_bytes{{{I}}} - node_memory_SwapFree_bytes{{{I}}}", "{{instance}}")],
            desc="Swap used per host. A little used swap on a node is normal (idle pages moved "
                 "out). Growth together with memory pressure means the host is short of RAM. "
                 "The k3s VMs have no swap and read 0. No alert rule.",
            unit="bytes", w=12, h=7),
        timeseries(
            "Memory pressure (PSI)",
            [(f"rate(node_pressure_memory_waiting_seconds_total{{{I}}}[$__rate_interval])", "{{instance}} some"),
             (f"rate(node_pressure_memory_stalled_seconds_total{{{I}}}[$__rate_interval])", "{{instance}} full")],
            desc="Share of time tasks stalled waiting for memory: 'some' = at least one task, "
                 "'full' = all non-idle tasks. The direct saturation signal; anything sustained "
                 "above a percent or two means reclaim is hurting. No alert rule.",
            unit="percentunit", max=1, w=12, h=7),
        timeseries(
            "OOM kills",
            [(f"increase(node_vmstat_oom_kill{{{I}}}[$__rate_interval])", "{{instance}}")],
            desc="Processes killed by the kernel out-of-memory killer in each window (the memory "
                 "error counter). Anything above 0 is an incident: a container or service was "
                 "killed for lack of memory. No alert rule; k3s tenant limits kill inside "
                 "cgroups, which this also counts.",
            unit="short", w=12, h=7),
    ])

    b.row("Disk I/O", [
        timeseries(
            "Disk busy",
            [(f"rate(node_disk_io_time_seconds_total{{{DISK}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}}")],
            desc="Share of time each block device had at least one request in flight (io_time). "
                 "Near 100 % on a spinning disk means it is saturated; an SSD can be busy and "
                 "still fast, so read it with latency. The monitoring CT's lines repeat pve2's: "
                 "the CT sees its host's disks. No alert rule.",
            unit="percentunit", max=1, w=12, h=7),
        timeseries(
            "Disk queue depth",
            [(f"rate(node_disk_io_time_weighted_seconds_total{{{DISK}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}}")],
            desc="Average number of requests waiting or in flight on each device (the weighted "
                 "io time rate). Above about 1 on a single spinning disk means requests are "
                 "queueing behind each other. No alert rule.",
            unit="short", decimals=2, w=12, h=7),
        timeseries(
            "Disk latency",
            [(f"rate(node_disk_read_time_seconds_total{{{DISK}, {I}}}[$__rate_interval])"
              f" / rate(node_disk_reads_completed_total{{{DISK}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}} read"),
             (f"rate(node_disk_write_time_seconds_total{{{DISK}, {I}}}[$__rate_interval])"
              f" / rate(node_disk_writes_completed_total{{{DISK}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}} write")],
            desc="Average time per completed read and write, queueing included. Milliseconds is "
                 "normal for an SSD; a spinning disk is slower (a few ms to tens of ms). Tens of "
                 "ms on an SSD, or hundreds on a disk, is a stall. A gap means no I/O in that "
                 "window. No alert rule.",
            unit="s", w=12, h=7),
        timeseries(
            "I/O pressure (PSI)",
            [(f"rate(node_pressure_io_waiting_seconds_total{{{I}}}[$__rate_interval])", "{{instance}} some"),
             (f"rate(node_pressure_io_stalled_seconds_total{{{I}}}[$__rate_interval])", "{{instance}} full")],
            desc="Share of time tasks stalled waiting for disk I/O: 'some' = at least one task, "
                 "'full' = all non-idle tasks. The direct saturation signal for storage: a few "
                 "percent is normal on a busy node, tens of percent means guests wait on disk. "
                 "No alert rule.",
            unit="percentunit", max=1, w=12, h=7),
    ], collapsed=True)

    b.row("Filesystems", [
        bargauge(
            "Space and inodes free",
            [(FS_FREE, "{{instance}} {{mountpoint}} space"),
             (FS_INODES_FREE, "{{instance}} {{mountpoint}} inodes")],
            desc="Free-space ratio of every mount (the HostFilesystemFull rule: red under "
                 "15 % for 15 minutes) and, for ext4, the free-inode ratio (no rule: running out "
                 "of inodes fails writes with space left). The /boot/efi mounts sit near 99 %.",
            unit="percentunit", max=1, w=12, h=9,
            thresholds=steps(("red", None), ("green", 0.15))),
        bargauge(
            "Disk runway, days until full", RUNWAY,
            desc="Days until each filesystem is full if the last 7 days of change continue "
                 "(linear, capped at 365). Under 30 days is worth a plan; under 7 is urgent. "
                 "Mirrors HostFilesystemFull, which fires only at 15 % free, so this warns "
                 "weeks earlier. A mount that is not shrinking reads 365.",
            unit="d", max=365, w=12, h=9, thresholds=lo_bad(30, 7)),
    ])

    b.row("Network", [
        timeseries(
            "Network throughput",
            [(f"rate(node_network_receive_bytes_total{{{NIC}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}} receive"),
             (f"rate(node_network_transmit_bytes_total{{{NIC}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}} transmit")],
            desc="Bytes per second on each host's physical interface (nic0 on the nodes, eth0 "
                 "on the CT and VMs; bridges and veth pairs are left out, they repeat the same "
                 "bytes). Read it against the 1 Gbit/s link (125 MB/s). The WAN-side picture is "
                 "on the Network boards. No alert rule here.",
            unit="Bps", w=12, h=7),
        timeseries(
            "Network errors and drops",
            [(f"rate(node_network_receive_errs_total{{{NIC}, {I}}}[$__rate_interval])"
              f" + rate(node_network_transmit_errs_total{{{NIC}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}} errors"),
             (f"rate(node_network_receive_drop_total{{{NIC}, {I}}}[$__rate_interval])"
              f" + rate(node_network_transmit_drop_total{{{NIC}, {I}}}[$__rate_interval])",
              "{{instance}} {{device}} drops")],
            desc="Packets per second with a hardware or driver error, and packets dropped by "
                 "the interface (receive and transmit summed). Errors should be 0. All three nodes "
                 "show a constant 0.1 receive drops/s (one frame every 10 seconds, identical "
                 "for days): background, not loss. A climb above that means a bad cable, a "
                 "full ring buffer or a saturated host. No alert rule.",
            unit="pps", w=12, h=7),
        timeseries(
            "Connection tracking used",
            [(f"node_nf_conntrack_entries{{{I}}} / node_nf_conntrack_entries_limit{{{I}}}", "{{instance}}")],
            desc="Entries in the kernel connection-tracking table over its limit. At 100 % new "
                 "connections are dropped (the kernel logs 'table full'). The k3s VMs track the "
                 "most (every pod connection); the dashed line marks 80 %. The monitoring CT "
                 "reads 0. No alert rule.",
            unit="percentunit", max=1, w=12, h=7,
            thresholds=_line_at(0.80), threshold_style="dashed"),
    ], collapsed=True)

    b.row("Clock and failed units", [
        timeseries(
            "Clock offset",
            [(f"node_timex_offset_seconds{{{I}}}", "{{instance}}")],
            desc="Offset of the kernel clock from its time source, per host. Healthy hosts sit "
                 "within a millisecond; a staircase or a growing drift means chrony cannot reach "
                 "its server. The alert (HostClockUnsynced) fires on the sync flag, not on the "
                 "offset; the top row counts it.",
            unit="s", min=None, w=12, h=7),
        table(
            "Failed units, by name",
            f'node_systemd_unit_state{{job="node", state="failed", {I}}} == 1',
            desc="Every unit in the failed state on the selected nodes and the CT (rule "
                 "HostSystemdUnitFailed, after 10 minutes). Empty is the good state. "
                 "Fix: systemctl status and journalctl -u on that host, then reset-failed.",
            columns=[("instance", "Host"), ("name", "Unit"), ("type", "Type")],
            w=12, h=7, empty_ok=True),
    ], collapsed=True)

    return [b]
