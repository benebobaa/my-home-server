"""Monitoring health: "can the other boards and the alerts be trusted?"

Top row = the answer (8 stats, same thresholds as the alerts they mirror).
Below: targets and scrapes, rule evaluation and alert delivery, the TSDB and
the disk it lives on, the monitoring CT's own resources.
Alert expressions mirrored here (rules/meta.yml): Watchdog, TargetDown,
PrometheusRuleFailures, AlertmanagerNotificationsFailing,
PrometheusTsdbNearRetentionCap; and (rules/hosts.yml) HostFilesystemFull,
HostMemoryLow for the CT itself.

Provenance: derived from the live metric names (Prometheus on CT 120), the
alert rules in services/monitoring/prometheus/rules/, and the previous
platform-monitoring board's queries (git HEAD, services/monitoring/grafana/
dashboards/platform-monitoring.json). No upstream mixin or vendor board was
consulted or adapted.

`instance="monitoring"` is written out, not a variable: this board is about
that one host, as the rules are.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, bargauge, table,
    steps, hi_bad, lo_bad, UP_DOWN,
)

CT = 'instance="monitoring"'
ROOT = CT + ', mountpoint="/"'
AVAIL = f"node_filesystem_avail_bytes{{{ROOT}}}"
SIZE = f"node_filesystem_size_bytes{{{ROOT}}}"
FREE = f"node_filesystem_free_bytes{{{ROOT}}}"
CORES = f'scalar(count(node_cpu_seconds_total{{{CT}, mode="idle"}}))'

# Days until the root filesystem is full if the last N days of change continue
# (same shape as the Overview's runway, one filesystem).
def runway(window: str) -> str:
    return (f"clamp_max({AVAIL} / clamp_min(-deriv({AVAIL}[{window}]), 1) / 86400, 365)")


# What Prometheus holds on disk: blocks + WAL + m-mapped head chunks. The size
# cap counts all three; the PrometheusTsdbNearRetentionCap rule counts blocks only.
TSDB_BLOCKS = 'prometheus_tsdb_storage_blocks_bytes{job="prometheus"}'
TSDB_WAL_HEAD = ('(prometheus_tsdb_wal_storage_size_bytes{job="prometheus"}'
                 ' + prometheus_tsdb_head_chunks_storage_size_bytes{job="prometheus"})')
TSDB_TOTAL = f"({TSDB_BLOCKS} + {TSDB_WAL_HEAD})"

# rule_group is "/etc/prometheus/rules/k8s.yml;k8s-tenants": keep the part after ";".
def by_group(expr: str) -> str:
    return f'label_replace({expr}, "g", "$1", "rule_group", ".*;(.*)")'


WATCHDOG_MAP = [{
    "type": "value",
    "options": {
        "0": {"text": "NOT FIRING", "color": "red", "index": 0},
        "1": {"text": "FIRING", "color": "green", "index": 1},
    },
}]

# the two receivers in alertmanager.yml: telegram, and healthchecks (a webhook)
INTEGRATIONS = 'integration=~"telegram|webhook"'


def boards():
    b = board(
        uid="homelab-obs-monitoring", title="Monitoring health", folder="Observability",
        description="Is the monitoring itself working, so the other boards and the alerts can be "
                    "trusted? Open it when an alert says the monitoring is blind (TargetDown, "
                    "PrometheusRuleFailures, AlertmanagerNotificationsFailing), when a board has "
                    "gaps, and weekly for the monitoring CT's disk runway.",
        method="use", filename="monitoring",
    )

    # -- the answer -------------------------------------------------------------
    b.row("Can the monitoring be trusted?", [
        problem_stat(
            "Targets down", 'count(up{tier!="best-effort"} == 0)',
            desc="Scrape targets that fail now, best-effort ones excluded (rule TargetDown: "
                 "warning after 5 minutes; best-effort targets raise it at info). A failing "
                 "scrape is a blind spot, not an outage: the board that uses it shows a gap. "
                 "The `ai` VM is best-effort and off by design, so it is not counted here "
                 "but is listed in the table below.", w=3),
        problem_stat(
            "Rule failures, 10 min",
            'sum(increase(prometheus_rule_evaluation_failures_total[10m]))',
            desc="Rule evaluations that failed in the last 10 minutes (rule PrometheusRuleFailures, "
                 "same window). Any failure means an alert is silently broken. Prometheus "
                 "Status > Rules names the group.", w=3),
        problem_stat(
            "Notifications failing, 15 min",
            'sum(increase(alertmanager_notifications_failed_total[15m]))',
            desc="Notifications Alertmanager could not deliver in the last 15 minutes (rule "
                 "AlertmanagerNotificationsFailing, same window). Red means Telegram or "
                 "healthchecks.io cannot be reached: alerts fire but nobody hears them.", w=3),
        stat(
            "Watchdog", 'max(ALERTS{alertname="Watchdog", alertstate="firing"}) or vector(0)',
            unit="none", thresholds=UP_DOWN, mappings=WATCHDOG_MAP, w=3,
            desc="The always-firing Watchdog rule (rules/meta.yml), as Prometheus sees it. FIRING "
                 "(green) proves Prometheus evaluates rules; NOT FIRING means evaluation stopped "
                 "or the rule is gone. Whether it reaches healthchecks.io is the dead-man's "
                 "switch panel further down."),
        stat(
            "TSDB blocks", TSDB_BLOCKS, unit="bytes",
            thresholds=steps(("green", None), ("red", 7e9)), w=3,
            desc="Block storage on disk. Red at 7e9 bytes (rule PrometheusTsdbNearRetentionCap, "
                 "info after 1 hour): the size cap is near and the oldest data is dropped before "
                 "30 days. The cap is 8 GiB, but the CT's disk fills first, see the "
                 "monitoring CT row."),
        stat(
            "Root disk free", f"{AVAIL} / {SIZE}", unit="percentunit",
            thresholds=lo_bad(0.20, 0.15), w=3, decimals=1,
            desc="Free space on the monitoring CT's root disk, which holds the TSDB, Grafana and "
                 "the OS. Red under 15 % is rule HostFilesystemFull (warning after 15 minutes); "
                 "orange under 20 % is a heads-up of this board, not an alert."),
        stat(
            "Disk runway, days", runway("7d"), unit="d", decimals=0, max=365,
            thresholds=lo_bad(30, 7), w=3,
            desc="Days until the root disk is full if the last 7 days of change continue "
                 "(linear, capped at 365). Under 30 is worth a look, under 7 is urgent. While the "
                 "TSDB is still filling toward its 30-day horizon this overstates the risk: read "
                 "the runway panel in the monitoring CT row before acting. No alert mirrors it."),
        stat(
            "Prometheus restarts, 7 d",
            'changes(process_start_time_seconds{job="prometheus"}[7d])',
            unit="short", thresholds=steps(("blue", None)), w=3,
            desc="How many times the Prometheus process started in 7 days: a reading, with no "
                 "threshold and no alert. Every restart replays the WAL and resets the pending "
                 "timers of alerts waiting on `for:`. A count that keeps climbing without a "
                 "deploy to explain it is worth `journalctl -u prometheus` on CT 120 (crash, "
                 "out-of-memory)."),
    ])

    # -- targets ---------------------------------------------------------------
    b.row("Targets and scrapes", [
        table(
            "Targets down now", "up == 0",
            desc="Every scrape target that fails right now, with its tier. Empty is good. "
                 "best-effort targets (the `ai` VM, off unless in use) only raise TargetDown at "
                 "info; standard and critical raise a warning. A target outside MGMT also needs "
                 "its hEX scrape rule (runbook: TargetDown).",
            columns=[("job", "Job"), ("instance", "Instance"), ("tier", "Tier")],
            sort_by="Job", descending=False, w=8, h=8, empty_ok=True),
        timeseries(
            "Slowest scrape, by job", 'max by (job) (scrape_duration_seconds)',
            desc="How long the slowest target of each job takes to answer a scrape. A scrape that "
                 "reaches its timeout (10 s, 30 s for the SNMP job) fails and becomes "
                 "TargetDown. A job whose line sits high and flat has a target that is off or "
                 "unreachable: the `ai` VM, off by design, holds service_dmz near 5 s.",
            unit="s", w=8, h=8),
        bargauge(
            "Samples per scrape, by job", 'sort_desc(sum by (job) (scrape_samples_scraped))',
            desc="Samples one scrape of each job returns, summed over its targets. It is the "
                 "weight each job puts on the TSDB: the Kubeletto cluster (service_dmz) and the "
                 "nodes dominate. A job that doubles overnight is a cardinality problem "
                 "(see series churn).",
            unit="short", w=8, h=8),
    ])

    # -- rules and alert delivery ----------------------------------------------
    b.row("Rules and alert delivery", [
        timeseries(
            "Rule group evaluation time, share of its interval",
            [(by_group("prometheus_rule_group_last_duration_seconds"
                       " / prometheus_rule_group_interval_seconds"), "{{g}}")],
            desc="How long each rule group's last evaluation took, as a share of its 30 s "
                 "interval. Over 100 % (dashed) the next evaluation is skipped and alerts go "
                 "late: see missed iterations. The k8s group is the slow one (a few seconds). "
                 "No alert mirrors it.",
            unit="percentunit", w=8, h=8, legend="list",
            thresholds=steps(("green", None), ("red", 1)), threshold_style="dashed"),
        timeseries(
            "Rule failures and missed iterations",
            [('sum(increase(prometheus_rule_evaluation_failures_total[$__rate_interval]))',
              "evaluation failures"),
             ('sum(increase(prometheus_rule_group_iterations_missed_total[$__rate_interval]))',
              "missed iterations")],
            desc="Failed rule evaluations (rule PrometheusRuleFailures: an alert that cannot be "
                 "evaluated never fires) and evaluations skipped because the previous one ran "
                 "long. Both should stay at zero; the dashed line is the first failure.",
            unit="short", w=8, h=8,
            thresholds=steps(("green", None), ("red", 1)), threshold_style="dashed"),
        timeseries(
            "Notifications sent, by receiver",
            [(f'sum by (integration) (rate(alertmanager_notifications_total{{{INTEGRATIONS}}}'
              '[$__rate_interval])) * 60', "{{integration}}")],
            desc="Notifications Alertmanager sends per minute: `telegram` is the chat, `webhook` "
                 "is the healthchecks.io Watchdog ping. Telegram is quiet unless something "
                 "fires; webhook is a steady pulse. A flat webhook line is the dead-man's "
                 "switch starving.",
            unit="cpm", w=6, h=8),
        timeseries(
            "Alert delivery failures",
            [(f'sum by (integration) (increase(alertmanager_notifications_failed_total{{{INTEGRATIONS}}}'
              '[$__rate_interval]))', "{{integration}} failed"),
             ('sum(increase(prometheus_notifications_errors_total[$__rate_interval]))',
              "prometheus to alertmanager errors"),
             ('sum(increase(prometheus_notifications_dropped_total[$__rate_interval]))',
              "prometheus dropped")],
            desc="Alertmanager failing to reach a receiver (rule AlertmanagerNotificationsFailing: "
                 "token revoked, internet down) and Prometheus failing to hand alerts to "
                 "Alertmanager. All zero is healthy; the dashed line is the first failure. "
                 "The failure reason is in `alertmanager_notifications_failed_total{reason}`.",
            unit="short", w=6, h=8,
            thresholds=steps(("green", None), ("red", 1)), threshold_style="dashed"),
        timeseries(
            "Alerts and silences in Alertmanager",
            [('sum by (state) (alertmanager_alerts{state=~"active|suppressed"})', "alerts {{state}}"),
             ('sum(alertmanager_silences{state="active"})', "silences active")],
            desc="Alerts Alertmanager holds: active ones are routed, suppressed ones are "
                 "inhibited (a down host hides its own scrape alerts) or silenced. A silence "
                 "that is still active after planned work hides real alerts: it should be back "
                 "to zero. The Watchdog counts as one active alert.",
            unit="short", w=6, h=8),
        timeseries(
            "Dead-man's switch: Watchdog pings, last 10 min",
            [('sum(increase(alertmanager_notifications_total{integration="webhook"}[10m]))',
              "pings sent in the trailing 10 min"),
             ('sum(increase(alertmanager_notification_requests_failed_total{integration="webhook"}[10m]))',
              "failed requests (retried)")],
            desc="The lab's end of the dead-man's switch: Alertmanager pings healthchecks.io "
                 "through the `webhook` receiver for the always-firing Watchdog (about one ping "
                 "per 2 minutes in practice; configured as every minute). healthchecks.io "
                 "alerts after 10 minutes without one (period 5 + grace 5), which is when "
                 "this line reaches 0 (dashed). The far end is provable only at "
                 "healthchecks.io: this shows the pings leave. Mirrors rule Watchdog.",
            unit="short", w=6, h=8,
            thresholds=steps(("red", None), ("green", 1)), threshold_style="dashed"),
    ])

    # -- TSDB and disk (review, collapsed) --------------------------------------
    b.row("TSDB: what it holds and how fast it grows", [
        timeseries(
            "TSDB size against the cap",
            [(TSDB_BLOCKS, "blocks"),
             (TSDB_WAL_HEAD, "WAL + head chunks"),
             ('prometheus_tsdb_retention_limit_bytes{job="prometheus"}', "size cap (retention.size)")],
            desc="Prometheus's disk use. Blocks are the 30 days of history; the WAL and head "
                 "chunks are the last couple of hours. The cap line is the live "
                 "retention.size (8 GiB: the flag value 8GB is read as GiB). The dashed line is "
                 "7e9 bytes of blocks, rule PrometheusTsdbNearRetentionCap (info). Past the cap "
                 "the oldest blocks are deleted early. The root disk is smaller than the cap "
                 "allows: see the 30-day panel in the monitoring CT row.",
            unit="bytes", w=8, h=8,
            thresholds=steps(("green", None), ("red", 7e9)), threshold_style="dashed"),
        timeseries(
            "Head series", 'prometheus_tsdb_head_series{job="prometheus"}',
            desc="Series currently in memory. It includes series that stopped receiving samples "
                 "(for example ended pods) until the next head compaction, so it runs above the "
                 "number being written now (samples per second times the scrape interval). "
                 "A step up that stays is new cardinality; a sawtooth that drops every two "
                 "hours is normal. No alert mirrors it.",
            unit="short", w=8, h=8, legend="hidden"),
        timeseries(
            "Samples appended per second",
            'sum(rate(prometheus_tsdb_head_samples_appended_total{job="prometheus"}[$__rate_interval]))',
            desc="Ingest rate: samples stored per second. It tracks the scrape targets (about the "
                 "total of Samples per scrape divided by 30 s). A sudden drop is missing scrapes; "
                 "a sudden rise is a job that added series. No alert mirrors it.",
            unit="ops", w=8, h=8, legend="hidden"),
        timeseries(
            "Series churn",
            [('rate(prometheus_tsdb_head_series_created_total{job="prometheus"}[$__rate_interval])',
              "created per second"),
             ('rate(prometheus_tsdb_head_series_removed_total{job="prometheus"}[$__rate_interval])',
              "removed per second")],
            desc="New series per second against series garbage-collected. Created staying high "
                 "means label values keep changing (pod names, ephemeral ports) and the head "
                 "carries many dead series; removed jumps at each 2-hourly head compaction. "
                 "The scrape_series_added series says which job creates them. No alert "
                 "mirrors it.",
            unit="ops", w=12, h=8),
        timeseries(
            "TSDB housekeeping failures",
            [('sum(increase(prometheus_tsdb_compactions_failed_total[$__rate_interval]))',
              "compactions failed"),
             ('sum(increase(prometheus_tsdb_head_truncations_failed_total[$__rate_interval]))',
              "head truncations failed"),
             ('sum(increase(prometheus_tsdb_wal_truncations_failed_total[$__rate_interval]))',
              "WAL truncations failed"),
             ('sum(increase(prometheus_tsdb_wal_corruptions_total[$__rate_interval]))',
              "WAL corruptions"),
             ('sum(increase(prometheus_tsdb_checkpoint_creations_failed_total[$__rate_interval]))',
              "checkpoints failed"),
             ('sum(increase(prometheus_tsdb_reloads_failures_total[$__rate_interval]))',
              "block reloads failed")],
            desc="Failed compactions, truncations, checkpoints and block reloads, and WAL "
                 "corruption. Each is zero on a healthy Prometheus; a compaction that fails keeps "
                 "retrying and the head grows until the disk is full. The dashed line is the "
                 "first failure. No alert mirrors it.",
            unit="short", w=12, h=8,
            thresholds=steps(("green", None), ("red", 1)), threshold_style="dashed"),
    ], collapsed=True)

    # -- the monitoring CT (USE) ------------------------------------------------
    cpu_legend = ("CT busy", "of which Prometheus")
    fs_30d = timeseries(
        "Root disk over 30 days: used, TSDB, everything else",
        [(f"{SIZE} - {FREE}", "root disk used"),
         (f'{TSDB_TOTAL}', "TSDB (blocks + WAL + head chunks)"),
         (f"({SIZE} - {FREE}) - scalar(sum({TSDB_TOTAL}))", "everything else (OS, Grafana, ...)")],
        desc="What fills the CT's root disk, over the last 30 days whatever the dashboard "
             "range. The TSDB grows until it holds a full retention window; everything else "
             "is flat (about 5 GB). Prometheus deletes whole 3-day blocks once they are older "
             "than 30 days: the first (the small early days, about 120 MB) is due around "
             "2026-11-12, so the line keeps rising until then and should flatten and fall as "
             "the heavier days age out. The disk has only about 7 GB for the TSDB, so the "
             "8 GiB size cap can never be reached: "
             "HostFilesystemFull (under 15 % free) fires at about 5 GB of blocks, long before "
             "PrometheusTsdbNearRetentionCap (7e9 bytes of blocks).",
        unit="bytes", w=12, h=8, legend="list")
    fs_30d.spec["timeFrom"] = "30d"
    fs_30d.spec["hideTimeOverride"] = False

    b.row("The monitoring CT (USE)", [
        timeseries(
            "CPU, the CT and Prometheus",
            [(f'1 - avg(rate(node_cpu_seconds_total{{{CT}, mode="idle"}}[$__rate_interval]))',
              cpu_legend[0]),
             (f'rate(process_cpu_seconds_total{{job="prometheus"}}[$__rate_interval]) / {CORES}',
              cpu_legend[1])],
            desc="Share of the CT's 2 cores in use, and the part Prometheus accounts for. "
                 "Grafana, the blackbox, SNMP and PVE exporters are not scraped for CPU, so the "
                 "gap between the lines is them plus the OS. Sustained near 100 % delays scrapes "
                 "and rule evaluation. No alert mirrors it (HostCpuHot is a temperature rule for "
                 "the Proxmox nodes).",
            unit="percentunit", w=8, h=8, max=1),
        timeseries(
            "Memory, the CT and Prometheus",
            [(f"node_memory_MemTotal_bytes{{{CT}}} - node_memory_MemAvailable_bytes{{{CT}}}",
              "CT used"),
             ('process_resident_memory_bytes{job="prometheus"}', "Prometheus resident"),
             (f"node_memory_SwapTotal_bytes{{{CT}}} - node_memory_SwapFree_bytes{{{CT}}}",
              "swap used"),
             (f"node_memory_MemTotal_bytes{{{CT}}} * 0.9", "HostMemoryLow line (90 % used)")],
            desc="Memory the CT uses (total minus available) and Prometheus's share, with the "
                 "line where less than 10 % is left (rule HostMemoryLow, warning after 15 "
                 "minutes). Swap in use means the CT has been short of RAM. Prometheus grows "
                 "with head series.",
            unit="bytes", w=8, h=8),
        timeseries(
            "Pressure stall time",
            [(f"rate(node_pressure_cpu_waiting_seconds_total{{{CT}}}[$__rate_interval])", "cpu"),
             (f"rate(node_pressure_io_waiting_seconds_total{{{CT}}}[$__rate_interval])", "io"),
             (f"rate(node_pressure_memory_waiting_seconds_total{{{CT}}}[$__rate_interval])",
              "memory")],
            desc="Saturation: the share of time at least one task in the CT waited for CPU, disk "
                 "or memory (kernel pressure stall information). Near zero is healthy; io "
                 "climbing means compaction or a slow shared disk is stalling Prometheus, "
                 "memory above a few percent means it is being squeezed. No alert mirrors it.",
            unit="percentunit", w=8, h=8),
        fs_30d,
        timeseries(
            "Disk runway, days until full",
            [(runway("7d"), "from the last 7 days"), (runway("30d"), "from the last 30 days")],
            desc="Days until the root disk is full if the trend of the last 7 (or 30) days "
                 "continued linearly. Not a compaction sawtooth (that is the few-hundred-MB "
                 "wiggle every couple of hours): the slope is steady and all of it is the TSDB "
                 "filling its 30-day window (see the 30-day panel). A linear runway overstates "
                 "the risk: retention deletes its first block around 2026-11-12, and an estimate "
                 "from the daily block sizes puts the low point near 19-20 % free around "
                 "2026-11-15 (about 0.5 GB above the 15 % alert), then a recovery to about 24 % "
                 "by early December. Check that against this panel. Dashed lines: 30 and 7 days. "
                 "HostFilesystemFull (under 15 % free) is the alert.",
            unit="d", w=12, h=8,
            thresholds=lo_bad(30, 7), threshold_style="dashed"),
    ], collapsed=True)
    return [b]
