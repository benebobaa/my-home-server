"""Hardware health: "is the physical hardware about to fail?" (USE: disks, CPUs, fans,
power and the GPU are resources; the board is mostly about errors and saturation.)

Provenance: derived from the live metric names and labels (smartmon_* from the
node_exporter textfile collector, node_hwmon_*, node_power_supply_*, node_cpu_*_throttles_total,
nvidia_smi_* from nvidia_gpu_exporter) and from the alert expressions. No upstream
mixin or vendor board was consulted.

Alert expressions mirrored (rules/hosts.yml, rules/gpu.yml): HostOnBattery,
DiskSmartFailing, DiskPendingSectors, DiskReallocatedSectorsGrowing, DiskHot,
HostCpuHot, GpuHot, GpuHardwareSlowdown, and HostTextfileCollectorStale (the SMART
data's own freshness).

The top-row tiles are whole-fleet: the Node selector filters the panels below them,
never the tiles that mirror an alert.
"""
from lib import (
    board, stat, problem_stat, timeseries, bargauge, table, state_timeline,
    var_query, steps, ZERO_GOOD,
)

PVE = 'job="node", instance=~"pve.*"'                 # the monitoring CT mirrors pve2's sysfs: pin to the nodes
SEL = PVE + ', instance=~"$instance"'                 # pinned and filtered by the Node selector

# HostCpuHot, verbatim inner expression: the CPU sensor is picked by hwmon chip name (NVMe and
# ACPI sensors share node_hwmon_temp_celsius and must not count).
CPU_TEMP_RULE = (
    'node_hwmon_temp_celsius{' + PVE + '}'
    ' * on (instance, chip) group_left ()'
    ' (node_hwmon_chip_names{job="node", chip_name=~"coretemp|k10temp"} * 0 + 1)'
)
CPU_TEMP = (
    'node_hwmon_temp_celsius{' + SEL + '}'
    ' * on (instance, chip) group_left ()'
    ' (node_hwmon_chip_names{' + PVE + ', chip_name=~"coretemp|k10temp"} * 0 + 1)'
)
OTHER_TEMP = (
    'node_hwmon_temp_celsius{' + SEL + '}'
    ' * on (instance, chip) group_left (chip_name)'
    ' (node_hwmon_chip_names{' + PVE + ', chip_name!~"coretemp|k10temp"} * 0 + 1)'
)
NVME_TEMP = (
    'node_hwmon_temp_celsius{' + SEL + ', sensor="temp1"}'
    ' * on (instance, chip) group_left ()'
    ' (node_hwmon_chip_names{' + PVE + ', chip_name="nvme"} * 0 + 1)'
)

# Disk identity: the SATA disks name their model in smartmon_device_info; the NVMe has none
# there (the collector reads no NVMe attributes), but node_exporter's nvme collector does.
DISK_MODEL = (
    '(smartmon_device_info{type!="nvme"}'
    ' or label_replace(label_replace(node_nvme_info{job="node"}, "disk", "/dev/$1", "device", "(.*)"),'
    ' "device_model", "$1", "model", "(.*)"))'
)

GPU_SLOWDOWN = '{__name__=~"nvidia_smi_clocks_event_reasons_hw_(slowdown|thermal_slowdown|power_brake_slowdown)"}'

AC_MAP = [{"type": "value", "options": {
    "0": {"text": "BATTERY", "color": "red", "index": 0},
    "1": {"text": "AC", "color": "green", "index": 1},
}}]
SLOWDOWN_MAP = [{"type": "value", "options": {
    "0": {"text": "none", "color": "green", "index": 0},
    "1": {"text": "SLOWDOWN", "color": "red", "index": 1},
}}]
HEALTH_MAP = [{"type": "value", "options": {
    "1": {"text": "healthy", "color": "green", "index": 0},
    "0": {"text": "FAILED", "color": "red", "index": 1},
}}]


def by_disk(expr: str) -> str:
    """One row per disk, keyed (instance, disk, device_model), for the merged disk table."""
    return ('max by (instance, disk, device_model) ((' + expr + ')'
            ' * on (instance, disk) group_left (device_model) ' + DISK_MODEL + ')')


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def _coloured(name: str, thresholds: dict, unit: str | None = None):
    props = [("thresholds", thresholds), ("color", {"mode": "thresholds"}),
             ("custom.cellOptions", {"type": "color-text"})]
    if unit:
        props.insert(0, ("unit", unit))
    return _col(name, *props)


DISK_TABLE_COLUMNS = [
    ("instance", "Host"), ("disk", "Disk"), ("device_model", "Model"),
    ("Value #A", "Health"), ("Value #B", "Temp"), ("Value #C", "Power-on hours"),
    ("Value #D", "Reallocated"), ("Value #E", "Reallocated, 7 d"),
    ("Value #F", "Pending"), ("Value #G", "Uncorrectable"), ("Value #H", "Wear value"),
]
DISK_TABLE_OVERRIDES = [
    _col("Health", ("mappings", HEALTH_MAP), ("custom.cellOptions", {"type": "color-text"})),
    _coloured("Temp", steps(("green", None), ("orange", 55)), unit="celsius"),  # DiskHot
    _col("Power-on hours", ("unit", "none")),
    _coloured("Reallocated, 7 d", steps(("green", None), ("orange", 1))),
    _coloured("Pending", ZERO_GOOD),                                            # DiskPendingSectors
    _coloured("Uncorrectable", ZERO_GOOD),
]


def last_30_days(panel):
    """The `ai` VM is on demand, so a 7-day window is often empty: show the last 30 days
    (Grafana's per-panel relative time) so the last session's readings stay visible."""
    panel.spec["timeFrom"] = "30d"
    return panel


def boards():
    b = board(
        uid="homelab-infra-hardware", title="Hardware health", folder="Infrastructure",
        description="Is the physical hardware about to fail? Disk SMART, CPU and board temperatures, "
                    "fans, AC power and the GPU, per node. Open it after a Disk*, Host*Hot, HostOnBattery "
                    "or Gpu* alert, or on the weekly review to see what is degrading.",
        method="use", filename="hardware", time_from="now-7d", refresh="5m",
        variables=[var_query("instance", "Node", "label_values(instance)", regex="/^pve[0-9]+$/",
                             multi=True, include_all=True)],
        # label_values(instance) + regex, not a selector form: build.py's --verify-live POSTs the
        # selector form to a GET-only endpoint and silently resolves nothing.
    )

    # ---- the answer ------------------------------------------------------------------
    b.row("Is the hardware about to fail?", [
        problem_stat(  # HostOnBattery
            "On battery", 'count(node_power_supply_online{' + PVE + '} == 0)',
            desc="Laptop nodes (pve2, pve3) whose AC adapter is not supplying power (rule "
                 "HostOnBattery, 1 minute, critical). pve1 is a desktop and has no such sensor. Read "
                 "it knowing that the batteries do not hold a node up (docs/hardware.md): a house "
                 "power cut takes the node down instead of showing here, so this goes red for an "
                 "unplugged adapter, and a real cut shows as the node unreachable and can leave a "
                 "step in the unsafe-shutdown counter below.", w=3),
        problem_stat(  # DiskSmartFailing
            "SMART failing", 'count(smartmon_device_smart_healthy == 0)',
            desc="Disks whose SMART overall health says FAILED (rule DiskSmartFailing, critical, no "
                 "delay). Red means copy the data off now (docs/runbooks/disk-rescue.md). Whole fleet, "
                 "not filtered by the Node selector.", w=3),
        problem_stat(  # DiskPendingSectors
            "Disks with unreadable sectors",
            'count(max by (instance, disk) ((smartmon_current_pending_sector_raw_value > 0)'
            ' or (smartmon_offline_uncorrectable_raw_value > 0)))',
            desc="Disks with pending or offline-uncorrectable sectors (rule DiskPendingSectors, "
                 "critical). Any number above 0 is data the disk can no longer read: pve3's old HDD "
                 "died this way with 8,448. Copy the data off and plan the replacement. Only the SATA "
                 "disks report these counters.", w=3),
        problem_stat(  # DiskReallocatedSectorsGrowing
            "Reallocated sectors grew, 24 h",
            'count(smartmon_reallocated_sector_ct_raw_value'
            ' - (smartmon_reallocated_sector_ct_raw_value offset 1d) > 0)', warn_only=True,
            desc="Disks whose reallocated-sector count rose in the last day (rule "
                 "DiskReallocatedSectorsGrowing, warning). A steady count is a disk that remapped "
                 "some sectors once and held (pve2's HDD has had 9 since 2026-10-09); growth is "
                 "a disk that is degrading. The table below shows the 7-day change per disk.", w=3),
        stat(  # DiskHot
            "Hottest disk", 'max(smartmon_temperature_celsius_raw_value)', unit="celsius", decimals=0,
            thresholds=steps(("green", None), ("orange", 55)),
            desc="The hottest SATA disk by its own SMART temperature (rule DiskHot: above 55 C for "
                 "30 minutes, warning). pve1's "
                 "NVMe is not in it: the collector reads no NVMe temperature, see the disk "
                 "temperature panel for the hwmon reading.", w=3),
        stat(  # HostCpuHot
            "Hottest CPU", 'max(' + CPU_TEMP_RULE + ')', unit="celsius", decimals=0,
            thresholds=steps(("green", None), ("orange", 90)),
            desc="The hottest CPU package across the three nodes (rule HostCpuHot: above 90 C for "
                 "10 minutes, warning), picked by hwmon chip name: Intel coretemp on pve2 and pve3, "
                 "AMD k10temp on pve1. The Ryzen throttles near 95 C.", w=3),
        stat(  # GpuHot
            "GPU temperature", 'max(nvidia_smi_temperature_gpu)', unit="celsius", decimals=0,
            thresholds=steps(("green", None), ("orange", 83)), no_value="ai off", empty_ok=True,
            desc="Temperature of the RTX 3060 in the `ai` VM (rule GpuHot: 83 C or more for 5 "
                 "minutes, warning; the card slows itself down from about 83 C). The VM is on "
                 "demand and off most of the time, so 'ai off' is the normal reading and not a "
                 "fault. The GPU row below keeps the last 30 days.", w=3),
        stat(  # GpuHardwareSlowdown
            "GPU hardware slowdown", 'max(' + GPU_SLOWDOWN + ')', unit="none",
            thresholds=ZERO_GOOD, mappings=SLOWDOWN_MAP, no_value="ai off", empty_ok=True,
            desc="1 when the board itself pulls the GPU clocks down, for heat (hw_thermal_slowdown) or "
                 "because the PSU asserts the power brake (hw_power_brake_slowdown) (rule "
                 "GpuHardwareSlowdown, 5 minutes). The ordinary 170 W power cap does not count. "
                 "'ai off' is the normal reading while the VM is off.", w=3),
    ])

    # ---- disks -----------------------------------------------------------------------
    b.row("Are the disks healthy?", [
        table(
            "Disks",
            [by_disk('smartmon_device_smart_healthy{instance=~"$instance"}'),
             by_disk('smartmon_temperature_celsius_raw_value{instance=~"$instance"}'),
             by_disk('smartmon_power_on_hours_raw_value{instance=~"$instance"}'),
             by_disk('smartmon_reallocated_sector_ct_raw_value{instance=~"$instance"}'),
             by_disk('smartmon_reallocated_sector_ct_raw_value{instance=~"$instance"}'
                     ' - (smartmon_reallocated_sector_ct_raw_value{instance=~"$instance"} offset 7d)'),
             by_disk('smartmon_current_pending_sector_raw_value{instance=~"$instance"}'),
             by_disk('smartmon_offline_uncorrectable_raw_value{instance=~"$instance"}'),
             by_disk('smartmon_wear_leveling_count_value{instance=~"$instance"}')],
            desc="Every disk the SMART collector sees (it runs every 15 minutes, never a self-test). "
                 "Health FAILED, Pending or Uncorrectable above 0 (rules DiskSmartFailing, "
                 "DiskPendingSectors) are red; Reallocated, 7 d above 0 is orange (rule "
                 "DiskReallocatedSectorsGrowing); Temp turns orange at 55 C (rule DiskHot). Wear "
                 "value is SMART attribute 177 as the drive normalises it (100 when new, the drive's "
                 "own threshold is lower), reported by pve3's SSD only. A blank cell means the drive "
                 "does not report that attribute; pve1's NVMe reports health and nothing else, so it "
                 "has no temperature, hours or wear here.",
            columns=DISK_TABLE_COLUMNS, overrides=DISK_TABLE_OVERRIDES,
            sort_by="Host", descending=False, w=24, h=7),
        timeseries(
            "Disk temperature",
            [('max by (instance, disk) (smartmon_temperature_celsius_raw_value{instance=~"$instance"})',
              "{{instance}} {{disk}}"),
             ('max by (instance) (' + NVME_TEMP + ')', "{{instance}} nvme (hwmon)")],
            desc="SMART temperature per SATA disk, plus pve1's NVMe from its hwmon sensor (the SMART "
                 "collector has no NVMe temperature, and rule DiskHot does not cover the NVMe). The "
                 "dashed line is 55 C (rule DiskHot, 30 minutes). Look for a disk that runs hotter "
                 "than its neighbours or climbs over weeks: dust or a failing fan.",
            unit="celsius", min=None, w=12, h=8,
            thresholds=steps(("green", None), ("orange", 55)), threshold_style="dashed"),
        timeseries(
            "Bad sectors",
            [('max by (instance, disk) (smartmon_reallocated_sector_ct_raw_value{instance=~"$instance"})',
              "{{instance}} {{disk}} reallocated"),
             ('max by (instance, disk) (smartmon_current_pending_sector_raw_value{instance=~"$instance"})',
              "{{instance}} {{disk}} pending"),
             ('max by (instance, disk) (smartmon_offline_uncorrectable_raw_value{instance=~"$instance"})',
              "{{instance}} {{disk}} uncorrectable")],
            desc="Sector counters per disk over the range. Pending or uncorrectable above 0 is critical "
                 "(rule DiskPendingSectors). A reallocated line that steps up is rule "
                 "DiskReallocatedSectorsGrowing; a flat line, even above 0, is a disk that "
                 "stabilised. Only the SATA disks report these.",
            unit="short", w=12, h=8),
        bargauge(
            "SMART data age",
            [('time() - node_textfile_mtime_seconds{job="node", instance=~"$instance", file=~".*/smartmon[.]prom"}',
              "{{instance}}")],
            desc="Seconds since each node's SMART file was written. The collector runs every 15 "
                 "minutes; over 1 hour (orange, rule HostTextfileCollectorStale) every disk alert "
                 "above is blind. After a power cut the laptops boot with a wrong clock and this "
                 "reads months until the next run clears it.",
            unit="s", max=7200, w=24, h=4,
            thresholds=steps(("green", None), ("orange", 3600))),
    ])

    # ---- thermals --------------------------------------------------------------------
    b.row("Is anything running hot?", [
        timeseries(
            "CPU package temperature",
            [('max by (instance) (' + CPU_TEMP + ')', "{{instance}}")],
            desc="CPU temperature per node, by hwmon chip name as rule HostCpuHot does it. The dashed "
                 "line is 90 C (10 minutes, warning). A baseline that creeps up over weeks at the same "
                 "load means dried paste or a clogged fan, long before the alert.",
            unit="celsius", min=None, w=12, h=8,
            thresholds=steps(("green", None), ("orange", 90)), threshold_style="dashed"),
        timeseries(
            "Board and drive sensors",
            [('max by (instance, chip_name) (' + OTHER_TEMP + ')', "{{instance}} {{chip_name}}")],
            desc="The other temperature sensors per node: the ACPI zone, the chipset (pch_skylake) "
                 "on the laptops and the NVMe on pve1. No alert watches these; they explain a hot "
                 "CPU (a chipset hot as well means a case problem, not a busy CPU).",
            unit="celsius", min=None, w=12, h=8),
        timeseries(
            "Fan speed",
            [('node_hwmon_fan_rpm{' + SEL + '}', "{{instance}} {{sensor}}")],
            desc="The CPU fan of the two laptop nodes. No alert watches it. A fan at 0 rpm "
                 "while the CPU is warm is a dead fan; a speed that rises for the same load is a "
                 "clogging heatsink. pve1 exposes no fan sensor, so it has no line here.",
            unit="rotrpm", w=12, h=7),
        timeseries(
            "CPU thermal throttle events",
            [('sum by (instance) (rate(node_cpu_package_throttles_total{' + SEL + '}[$__rate_interval]))',
              "{{instance}} package"),
             ('sum by (instance) (rate(node_cpu_core_throttles_total{' + SEL + '}[$__rate_interval]))',
              "{{instance}} cores")],
            desc="Times per second the CPU slowed itself down for heat (kernel thermal-throttle "
                 "counters: pve2 and pve3 report them, pve1's Ryzen exposes none). No alert watches it. The line "
                 "should be flat at 0; any rise means the temperature panel is hiding a CPU that "
                 "is being held back.",
            unit="ops", w=12, h=7),
    ])

    # ---- power -----------------------------------------------------------------------
    b.row("Is the power path OK?", [
        state_timeline(
            "AC power",
            [('node_power_supply_online{' + SEL + '}', "{{instance}} {{power_supply}}")],
            desc="Whether the laptop nodes' AC adapter is supplying power (rule HostOnBattery). Red is "
                 "BATTERY. pve1 is a desktop with no power-supply sensor. Because the batteries "
                 "do not keep a node up (docs/hardware.md), a house power cut does not draw a red "
                 "bar: the node just disappears. Read the unsafe-shutdown panel for those.",
            mappings=AC_MAP, w=8, h=6),
        table(
            "Battery",
            'node_power_supply_info{' + PVE + ', instance=~"$instance", type="Battery"}',
            desc="The kernel's view of each laptop battery. 'Not charging' while on AC is normal; "
                 "'Discharging' means AC is lost. There is no charge or capacity reading: BAT0 "
                 "reports none (docs/hardware.md), so remaining runtime cannot be shown here.",
            columns=[("instance", "Host"), ("power_supply", "Supply"), ("status", "Status")],
            sort_by="Host", descending=False, w=6, h=6),
        timeseries(
            "Unsafe shutdowns",
            [('max by (instance, disk) (smartmon_unsafe_shutdown_count_raw_value{instance=~"$instance"})',
              "{{instance}} {{disk}}")],
            desc="The SSD's own count of power losses without a clean shutdown (SMART attribute 192). "
                 "Each step up is a hard power-off: a house power cut, a held power button or a "
                 "crash reset. It is the only after-the-fact power-cut record the lab has while the "
                 "batteries carry nothing. No alert watches it. Only pve2's Kingston SSD reports it.",
            unit="short", min=None, w=10, h=6),
    ])

    # ---- GPU -------------------------------------------------------------------------
    b.row("GPU (the `ai` VM, on demand)", [
        last_30_days(timeseries(
            "GPU temperature over time",
            [('max by (instance) (nvidia_smi_temperature_gpu)', "{{instance}} temperature")],
            desc="RTX 3060 temperature. The dashed line is 83 C (rule GpuHot, 5 minutes, warning). "
                 "The VM is on demand, so this is empty while it is off (by design, not a fault) and "
                 "shows the last 30 days whatever the dashboard's range is. A run that sits at the "
                 "line means dust, a dead fan or a hot room.",
            unit="celsius", min=None, w=12, h=8, empty_ok=True,
            thresholds=steps(("green", None), ("orange", 83)), threshold_style="dashed")),
        last_30_days(timeseries(
            "GPU fan",
            [('max by (instance) (nvidia_smi_fan_speed_ratio)', "{{instance}} fan")],
            desc="GPU fan speed as a share of its maximum. No alert watches it. Empty while the VM is "
                 "off; last 30 days. A fan at 0 % under load with a rising temperature is a stopped "
                 "fan.",
            unit="percentunit", max=1, w=12, h=8, empty_ok=True)),
        last_30_days(timeseries(
            "GPU power draw vs limit",
            [('max by (instance) (nvidia_smi_power_draw_watts)', "{{instance}} draw"),
             ('max by (instance) (nvidia_smi_power_limit_watts)', "{{instance}} limit")],
            desc="Power the GPU draws against its power limit (170 W). Sitting on the limit under load is "
                 "normal and is not alerted (sw_power_cap); a draw that cannot reach the limit with "
                 "the clocks pulled down is the power brake of rule GpuHardwareSlowdown. Empty while the "
                 "VM is off; last 30 days.",
            unit="watt", w=12, h=8, empty_ok=True)),
        last_30_days(timeseries(
            "GPU graphics clock",
            [('max by (instance) (nvidia_smi_clocks_current_graphics_clock_hz)', "{{instance}} current"),
             ('max by (instance) (nvidia_smi_clocks_max_graphics_clock_hz)', "{{instance}} maximum")],
            desc="Graphics clock against the card's maximum. A clock far under the maximum while "
                 "the GPU is busy and the power draw is below its limit means the board is holding "
                 "it down (see the slowdown reasons). Idle clocks are low by design. Empty while the VM is "
                 "off; last 30 days.",
            unit="hertz", w=12, h=8, empty_ok=True)),
        last_30_days(timeseries(
            "GPU memory used",
            [('max by (instance) (nvidia_smi_memory_used_bytes)', "{{instance}} used"),
             ('max by (instance) (nvidia_smi_memory_total_bytes)', "{{instance}} total")],
            desc="VRAM in use against the card's 12 GiB. No alert: vLLM and SGLang pre-allocate about "
                 "90 % of VRAM by design (rules/gpu.yml), so a high line is normal. Empty while the "
                 "VM is off; last 30 days.",
            unit="bytes", w=12, h=8, empty_ok=True)),
        last_30_days(state_timeline(
            "GPU slowdown reasons",
            [('max by (instance) (nvidia_smi_clocks_event_reasons_hw_slowdown)', "{{instance}} hardware"),
             ('max by (instance) (nvidia_smi_clocks_event_reasons_hw_thermal_slowdown)', "{{instance}} thermal"),
             ('max by (instance) (nvidia_smi_clocks_event_reasons_hw_power_brake_slowdown)',
              "{{instance}} power brake")],
            desc="The three hardware clock-event reasons that rule GpuHardwareSlowdown watches. Any red "
                 "bar longer than 5 minutes alerts: thermal means airflow, power brake means the PSU or "
                 "its PCIe cable cannot keep up. The normal software power cap is not shown. Empty "
                 "while the VM is off; last 30 days.",
            mappings=SLOWDOWN_MAP, thresholds=ZERO_GOOD, w=12, h=8, empty_ok=True)),
    ], collapsed=True)
    return [b]
