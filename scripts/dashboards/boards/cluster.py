"""Proxmox cluster: "is the cluster healthy, are the guests running, where does the
load sit, is storage OK, are backups covered?" (USE: nodes, guests and storage are
resources.) The 3-node cluster `homelab` as prometheus-pve-exporter reports it; the
cluster-wide series come from one node only (job pve).

Provenance: derived from the live metric names and labels (pve_*, node_lvm_*,
node_memory_*) and from the alert expressions. No upstream mixin or vendor board
was consulted.

Alert expressions mirrored (rules/cluster.yml, rules/hosts.yml): PveClusterNotQuorate,
PveNodeDown, PveGuestDown, PveStorageFilling, PveGuestNotBackedUp, ThinPoolFilling,
ThinPoolCritical, ThinPoolMetadataFilling, and HostMemoryLow (node memory).
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, bargauge, table, text,
    state_timeline, var_query, steps, hi_bad, lo_bad,
)

GUESTS = 'id=~"(lxc|qemu)/.*"'
NODES = 'id=~"node/.*"'
STORAGES = 'id=~"storage/.*"'

# PveGuestNotBackedUp, verbatim (rules/cluster.yml; the PBS CT is excluded on purpose).
NOT_BACKED_UP = (
    '(pve_not_backed_up_info == 1)'
    ' * on (id) group_left (name, node) pve_guest_info{template="0"}'
    ' unless on (id) pve_guest_info{name="pbs"}'
)

# PveGuestDown, verbatim: onboot guests only (the archive CT and the `ai` VM are off by design).
GUEST_DOWN = (
    '(pve_up{' + GUESTS + '} == 0)'
    ' * on (id) group_left (name, node) pve_guest_info'
    ' and on (id) (pve_onboot_status == 1)'
)

# PveStorageFilling, verbatim: every storage except the thin pools, which the ThinPool* rules watch.
STORAGE_RATIO = (
    'pve_disk_usage_bytes{' + STORAGES + ', id!~"storage/.*/local-lvm"}'
    ' / pve_disk_size_bytes{' + STORAGES + ', id!~"storage/.*/local-lvm"}'
)

# The same quotient for any storage, joined to its name. A shared storage (pbs, pbs-replica)
# is reported by all three nodes with identical numbers: callers dedupe with max by (storage).
RATIO_ALL = 'pve_disk_usage_bytes{' + STORAGES + '} / pve_disk_size_bytes{' + STORAGES + '}'

NODE_OF_ID = 'label_replace(pve_memory_size_bytes{' + NODES + '}, "node", "$1", "id", "node/(.*)")'

# HostMemoryLow (rules/hosts.yml) is MemAvailable / MemTotal < 0.10 on the node job.
NODE_MEM_USED = (
    '1 - node_memory_MemAvailable_bytes{job="node", instance=~"pve.*"}'
    ' / node_memory_MemTotal_bytes{job="node", instance=~"pve.*"}'
)


def by_guest(expr: str) -> str:
    """One row per guest, keyed (id, name, node, type), for the merged guest table.
    pve_onboot_status carries instance=<the guest's node> while every other pve series
    carries instance=pve2, so each query is aggregated down to the join key first."""
    return ('max by (id, name, node, type) ((' + expr + ')'
            ' * on (id) group_left (name, node, type) pve_guest_info{node=~"$node"})')


def with_name(expr: str) -> str:
    """Attach the guest name to a per-id series, restricted to the selected nodes."""
    return '(' + expr + ') * on (id) group_left (name) pve_guest_info{node=~"$node"}'


STATE_MAP = [{"type": "value", "options": {
    "0": {"text": "stopped", "color": "orange", "index": 0},
    "1": {"text": "running", "color": "green", "index": 1},
}}]
BOOT_MAP = [{"type": "value", "options": {
    "0": {"text": "no", "index": 0},
    "1": {"text": "yes", "index": 1},
}}]


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


GUEST_TABLE_COLUMNS = [
    ("name", "Name"), ("id", "ID"), ("node", "Node"), ("type", "Type"),
    ("Value #A", "State"), ("Value #B", "On boot"), ("Value #C", "vCPUs"),
    ("Value #D", "CPU"), ("Value #E", "Memory used"), ("Value #F", "Memory limit"),
    ("Value #G", "Memory %"),
]
GUEST_TABLE_OVERRIDES = [
    _col("State", ("mappings", STATE_MAP), ("custom.cellOptions", {"type": "color-text"})),
    _col("On boot", ("mappings", BOOT_MAP)),
    _col("CPU", ("unit", "percentunit")),
    _col("Memory used", ("unit", "bytes")),
    _col("Memory limit", ("unit", "bytes")),
    _col("Memory %", ("unit", "percentunit")),
]


def boards():
    b = board(
        uid="homelab-infra-proxmox", title="Proxmox cluster", folder="Infrastructure",
        description="Is the Proxmox cluster healthy? Quorum, nodes, guests that should run, "
                    "where the load sits, storage and thin-pool headroom, backup coverage. "
                    "Open it after a Pve*, ThinPool* or PveStorageFilling alert, or on the weekly review.",
        method="use", filename="proxmox", time_from="now-24h",
        # label_values(node) + regex, not label_values(pve_node_info, name): build.py's
        # --verify-live POSTs the selector form to a GET-only endpoint and silently
        # resolves nothing, which leaves every $node query empty in the check.
        variables=[var_query("node", "Node", "label_values(node)", regex="/^pve[0-9]+$/",
                             multi=True, include_all=True)],
    )

    # ---- the answer ----------------------------------------------------------------
    b.row("Is the cluster healthy?", [
        up_stat(  # PveClusterNotQuorate
            "Cluster quorum", 'max(pve_cluster_info{quorate="1"}) or vector(0)',
            desc="Proxmox cluster quorum (rule PveClusterNotQuorate). Three nodes: one down keeps "
                 "quorum, two down lose it. Not quorate means guests keep running but start, stop, "
                 "config changes and backups lock. DOWN also shows when the exporter has no cluster "
                 "series at all. Whole cluster; the Node selector does not filter this tile.", w=3),
        problem_stat(  # PveNodeDown
            "Nodes down", 'count(pve_up{' + NODES + '} == 0)',
            desc="Nodes the cluster sees offline (rule PveNodeDown, 2 minutes). Red at 1 or more. "
                 "The alert's severity follows the node's tier: pve2 and pve3 critical, pve1 "
                 "warning, because it is always on since ADR 0023. Whole cluster, not filtered "
                 "by the Node selector.", w=3),
        problem_stat(  # PveGuestDown
            "Guests down", 'count(' + GUEST_DOWN + ')',
            desc="Guests with onboot=1 that are not running (rule PveGuestDown: 5 minutes). The "
                 "archive CT and the `ai` VM have onboot=0 and are stopped by design, so they never "
                 "count here; the guest table below shows them as 'stopped'.", w=3),
        problem_stat(  # PveGuestNotBackedUp
            "Guests not backed up", 'count(' + NOT_BACKED_UP + ')',
            desc="Guests in no backup job (rule PveGuestNotBackedUp, 1 hour; the PBS CT is excluded "
                 "on purpose). It counts coverage only: there is no backup success or age metric "
                 "yet, so a green tile does not prove the last backup worked. A freshness collector "
                 "is planned and will add panels here.", w=3),
        stat(  # ThinPoolFilling 85, ThinPoolCritical 92
            "Thin pool data, fullest", 'max(node_lvm_thin_pools_allocated)', unit="percent",
            decimals=1, thresholds=hi_bad(85, 92),
            desc="Data allocated in the fullest guest thin pool (pve/data, one per node). Orange "
                 "above 85 % (rule ThinPoolFilling), red above 92 % (ThinPoolCritical). The pool "
                 "auto-extends at 80 % into a small buffer; at 100 % every guest on it freezes. "
                 "Whole cluster.", w=3),
        stat(  # ThinPoolMetadataFilling 75
            "Thin pool metadata, fullest", 'max(node_lvm_thin_pools_metadata)', unit="percent",
            decimals=1, thresholds=steps(("green", None), ("orange", 75)),
            desc="Metadata used in the fullest thin pool. Orange above 75 % (rule "
                 "ThinPoolMetadataFilling). Full metadata stops the pool like full data does; the "
                 "fix is lvextend --poolmetadatasize. Whole cluster.", w=3),
        stat(  # PveStorageFilling 0.90
            "Storage fullest", 'max(' + STORAGE_RATIO + ')', unit="percentunit", decimals=1,
            thresholds=steps(("green", None), ("orange", 0.90)),
            desc="The fullest directory or PBS storage (rule PveStorageFilling: over 90 % for 30 "
                 "minutes, warning). Thin pools are not in it (tiles to the left). Today the PBS "
                 "datastore is the one to watch; the runway panel below turns this into days.", w=3),
        stat(  # HostMemoryLow 0.10 available
            "Node memory, fullest", 'max(' + NODE_MEM_USED + ')', unit="percentunit", decimals=1,
            thresholds=steps(("green", None), ("orange", 0.90)),
            desc="Memory in use on the fullest Proxmox node, 1 minus MemAvailable/MemTotal (rule "
                 "HostMemoryLow fires below 10 % available for 15 minutes, which is 90 % here). The "
                 "k3s VMs fall under the same rule but are not shown on this board.", w=3),
    ])

    # ---- guests ----------------------------------------------------------------------
    b.row("Is every guest that should run, running?", [
        table(
            "Guests",
            [by_guest('pve_up{' + GUESTS + '}'),
             by_guest('max by (id) (pve_onboot_status)'),
             by_guest('pve_cpu_usage_limit{' + GUESTS + '}'),
             by_guest('pve_cpu_usage_ratio{' + GUESTS + '}'),
             by_guest('pve_memory_usage_bytes{' + GUESTS + '}'),
             by_guest('pve_memory_size_bytes{' + GUESTS + '}'),
             by_guest('pve_memory_usage_bytes{' + GUESTS + '} / pve_memory_size_bytes{' + GUESTS + '}')],
            desc="Every guest on the selected nodes: where it runs, whether it is running, whether it "
                 "starts on boot, and CPU and memory against its own limit. Stopped guests sort "
                 "first. A stopped guest with On boot = yes is what rule PveGuestDown alerts on; "
                 "stopped with On boot = no (archive, ai) is by design. CPU is the share of the "
                 "guest's own vCPUs. A VM's memory can read slightly above 100 % (k3s does at "
                 "the time of writing): Proxmox reports what the host sees the VM using, and the "
                 "number is not clamped here.",
            columns=GUEST_TABLE_COLUMNS, overrides=GUEST_TABLE_OVERRIDES,
            sort_by="State", descending=False, h=12),
        state_timeline(
            "Guests that start on boot",
            [(with_name('pve_up{' + GUESTS + '}') + ' and on (id) (pve_onboot_status == 1)', "{{name}}")],
            desc="Up (green) and down (red) per guest that should always run (onboot=1), over the "
                 "dashboard's time range. A red bar is what rule PveGuestDown measures; a node "
                 "reboot shows as a short red bar on every guest it hosts. The `ai` VM and the archive "
                 "CT are not listed: they are off by design.", w=14, h=8),
        state_timeline(
            "Nodes and quorum",
            [('pve_up{' + NODES + '}', "{{id}}"),
             ('max(pve_cluster_info{quorate="1"}) or vector(0)', "quorum")],
            desc="Each node's state as the cluster sees it (rule PveNodeDown) and quorum (rule "
                 "PveClusterNotQuorate) over time. Two nodes red at once, with quorum red, is the "
                 "dangerous case. HA is not in use here: no HA resources exist, so every "
                 "pve_ha_state series reads 0.", w=10, h=8),
    ])

    # ---- load ------------------------------------------------------------------------
    b.row("Where does the load sit?", [
        timeseries(
            "CPU used by guest, in cores",
            [(with_name('pve_cpu_usage_ratio{' + GUESTS + '} * on (id) pve_cpu_usage_limit'), "{{name}}")],
            desc="CPU each guest uses, as cores: its CPU ratio times its vCPU count, so guests of "
                 "different sizes compare directly. The legend shows the mean and the peak over the "
                 "range. Utilisation, not an alert: a guest pinned at its vCPU count is starved "
                 "(see the vCPUs column in the table); a node's total is below.",
            unit="short", decimals=2, w=12, h=9, legend="table", legend_calcs=("mean", "max")),
        timeseries(
            "Node CPU",
            [('pve_cpu_usage_ratio{' + NODES + '}', "{{id}}")],
            desc="CPU utilisation of each Proxmox node, share of all its cores. No alert watches "
                 "CPU load (HostCpuHot is temperature, on the Hardware board). Sustained 90 % or more "
                 "means a guest needs moving or limiting.",
            unit="percentunit", max=1, w=12, h=9),
        timeseries(
            "Memory used by guest",
            [(with_name('pve_memory_usage_bytes{' + GUESTS + '}'), "{{name}}")],
            desc="Memory each guest uses, as Proxmox reports it. Compare with the Memory limit column "
                 "in the guest table: a guest near its limit is killed by the kernel (CT) or swaps "
                 "(VM). A VM can read slightly above its configured size.",
            unit="bytes", w=12, h=9, legend="table", legend_calcs=("lastNotNull", "max")),
        timeseries(
            "Node memory used",
            [(NODE_MEM_USED, "{{instance}}")],
            desc="Memory in use per Proxmox node, 1 minus MemAvailable/MemTotal. The dashed line is "
                 "the 90 % that rule HostMemoryLow fires at (10 % available for 15 minutes). pve3 "
                 "has the least RAM, so it is the first to run out.",
            unit="percentunit", max=1, w=12, h=9,
            thresholds=steps(("green", None), ("orange", 0.90)), threshold_style="dashed"),
        bargauge(
            "Memory committed vs node memory",
            [('sum by (node) (pve_memory_size_bytes{' + GUESTS + '} * on (id) group_left (node) pve_guest_info)'
              ' / on (node) ' + NODE_OF_ID, "{{node}} configured"),
             ('sum by (node) (pve_memory_size_bytes{' + GUESTS + '} * on (id) group_left (node)'
              ' (pve_guest_info and on (id) (pve_up == 1))) / on (node) ' + NODE_OF_ID,
              "{{node}} running")],
            desc="Memory promised to guests as a share of each node's RAM: 'configured' counts every "
                 "guest placed on the node, 'running' only those up now. Over 100 % (orange) means "
                 "the guests could together claim more than the node has. No alert mirrors this. "
                 "pve1's configured bar includes the 24 GiB `ai` VM, so it reads far above its "
                 "running bar while the VM is off.",
            unit="percentunit", max=1, w=24, h=7,
            thresholds=steps(("green", None), ("orange", 1.0))),
    ])

    b.row("Network and disk by guest", [
        timeseries(
            "Network by guest",
            [('sum by (name) ((rate(pve_network_receive_bytes_total{' + GUESTS + '}[$__rate_interval])'
              ' + rate(pve_network_transmit_bytes_total{' + GUESTS + '}[$__rate_interval]))'
              ' * on (id) group_left (name) pve_guest_info{node=~"$node"})', "{{name}}")],
            desc="Bytes per second in plus out on each guest's virtual NIC. Shows which guest moves "
                 "the data. A step change with no deploy behind it is worth a look.",
            unit="Bps", w=12, h=8, legend="table", legend_calcs=("mean", "max")),
        timeseries(
            "Disk I/O by guest",
            [('sum by (name) ((rate(pve_disk_read_bytes_total{' + GUESTS + '}[$__rate_interval])'
              ' + rate(pve_disk_written_bytes_total{' + GUESTS + '}[$__rate_interval]))'
              ' * on (id) group_left (name) pve_guest_info{node=~"$node"})', "{{name}}")],
            desc="Bytes per second read plus written on each guest's disks. The thin pool and the "
                 "SSDs are shared, so one guest writing hard slows the rest. Sustained high writes "
                 "from a stateful guest (monitoring, postgres, the k3s VMs) also wear the SSD.",
            unit="Bps", w=12, h=8, legend="table", legend_calcs=("mean", "max")),
    ], collapsed=True)

    # ---- storage ---------------------------------------------------------------------
    b.row("Is storage OK?", [
        bargauge(
            "Storage used",
            [('max by (storage) ((' + RATIO_ALL + ') * on (id) group_left (storage)'
              ' pve_storage_info{plugintype="pbs"})', "{{storage}} (PBS datastore)"),
             ('(' + RATIO_ALL + ') * on (id) group_left (storage, node) pve_storage_info{plugintype="dir"}',
              "{{storage}} on {{node}}")],
            desc="How full each directory and PBS storage is. Orange from 90 % (rule "
                 "PveStorageFilling, 30 minutes). `pbs` is the nightly backup datastore (it lives on "
                 "the PBS CT's own disk) and `pbs-replica` its off-node copy; both are shared storages, "
                 "so each shows once. The thin pools (local-lvm) are on the next panels.",
            unit="percentunit", max=1, w=8, h=8,
            thresholds=steps(("green", None), ("orange", 0.90))),
        timeseries(
            "Storage used over time",
            [('max by (storage) ((' + RATIO_ALL + ') * on (id) group_left (storage)'
              ' pve_storage_info{plugintype=~"pbs|dir"})', "{{storage}}")],
            desc="The same ratios over time, with the 90 % alert line (rule PveStorageFilling) dashed. "
                 "A steady climb towards the line is the thing to plan for; a flat line is fine at "
                 "any height. `local` is the fullest of the three nodes' root storages.",
            unit="percentunit", max=1, w=8, h=8,
            thresholds=steps(("green", None), ("red", 0.90)), threshold_style="dashed"),
        bargauge(
            "Days until a storage reaches 90 %",
            [('min by (storage) (clamp_max(clamp_min(0.9 * pve_disk_size_bytes{' + STORAGES + ', id!~"storage/.*/local-lvm"}'
              ' - pve_disk_usage_bytes{' + STORAGES + ', id!~"storage/.*/local-lvm"}, 0)'
              ' / clamp_min(deriv(pve_disk_usage_bytes{' + STORAGES + ', id!~"storage/.*/local-lvm"}[7d]), 1)'
              ' / 86400, 365) * on (id) group_left (storage) pve_storage_info)', "{{storage}}")],
            desc="Days until each storage crosses the 90 % line of rule PveStorageFilling if the last "
                 "7 days of change continue (linear, capped at 365; flat or shrinking reads 365; "
                 "already over the line reads 0). Under 30 days is worth a plan, under 7 is urgent. "
                 "A freshly seeded copy like `pbs-replica` grows fast at first and reads low.",
            unit="d", max=365, w=8, h=8, thresholds=lo_bad(30, 7)),
        timeseries(
            "Thin pool data allocated",
            [('node_lvm_thin_pools_allocated{node=~"$node"}', "{{instance}}")],
            desc="Data allocated in each node's guest thin pool (pve/data). Dashed lines are the alert "
                 "thresholds: 85 % ThinPoolFilling, 92 % ThinPoolCritical. The pool auto-extends at "
                 "80 % into a small VG buffer, so sitting above 85 % means the buffer is being used "
                 "up; at 100 % every guest on the pool freezes. pve3 has the smallest pool. Fix: "
                 "pct fstrim in the guests, or add disk.",
            unit="percent", max=100, w=12, h=8,
            thresholds=hi_bad(85, 92), threshold_style="dashed"),
        timeseries(
            "Thin pool metadata used",
            [('node_lvm_thin_pools_metadata{node=~"$node"}', "{{instance}}")],
            desc="Metadata used in each thin pool. The dashed line is 75 % (rule "
                 "ThinPoolMetadataFilling). Metadata grows with the number of snapshots and blocks, "
                 "not with data; it is far from the line today and moves slowly.",
            unit="percent", max=100, w=12, h=8,
            thresholds=steps(("green", None), ("orange", 75)), threshold_style="dashed"),
    ])

    # ---- backups ---------------------------------------------------------------------
    b.row("Are backups covered?", [
        table(
            "Guests in no backup job", NOT_BACKED_UP,
            desc="Guests that no backup job covers (rule PveGuestNotBackedUp: still listed after 1 "
                 "hour it alerts). Empty is the goal. The nightly job (PBS, 02:30 WIB) covers every guest "
                 "except the PBS CT itself, whose disk is the datastore, so a new guest is covered "
                 "automatically; an entry here means the job was edited, disabled or removed, or "
                 "the guest is one the rule does not exclude. This is coverage only: there is no "
                 "backup success or age metric yet.",
            columns=[("name", "Guest"), ("id", "ID"), ("node", "Node")],
            sort_by="Guest", descending=False, w=14, h=6, empty_ok=True),
        text("Not measured yet", (
            "**Backup freshness is not on this board.** Proxmox exports whether a guest is in a "
            "backup job, not whether the last run succeeded or how old it is. A freshness "
            "collector is planned and will add panels here. Until then a failed nightly run "
            "reaches Telegram only as a Proxmox notification, and a restore is the real "
            "proof (`docs/runbooks/backup-restore.md`)."), w=10, h=6),
    ])
    return [b]
