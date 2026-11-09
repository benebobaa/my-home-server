"""Log and trace stores: "are VictoriaLogs and VictoriaTraces taking data in and keeping it?"

Top row = the answer (8 stats, same thresholds as the alerts they mirror).
Below: ingest and drops, disk against the cap and retention, the processes'
CPU and memory, and the stores' own warnings and errors.
Alert expressions mirrored here: LogsIngestionStopped, LogsNearDiskCap
(rules/logs.yml), TracesNearDiskCap (rules/traces.yml); down is HttpProbeFailed
and TargetDown (rules/network.yml, rules/meta.yml).

Provenance: derived from the live metric names (Prometheus on CT 120), the
alert rules in services/monitoring/prometheus/rules/, and the previous
platform-logs and platform-traces boards' queries (git HEAD,
services/monitoring/grafana/dashboards/platform-logs.json and
platform-traces.json). No upstream mixin or vendor board was consulted or
adapted.

`instance="logs"` and `instance="traces"` are written out, not a variable: the
board is about those two stores, as the rules are.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, logs,
    steps,
)

VL = 'job="service", instance="logs"'
VT = 'job="service", instance="traces"'
BOTH = 'job="service", instance=~"logs|traces"'

# Disk caps (services/logs/setup.sh DISK_CAP, services/traces/setup.sh) and the
# alert thresholds from the rules. The cap itself is read live from the stores'
# vl_/vt_max_disk_space_usage_bytes; these only turn the rules' absolute bytes
# into a share of it.
LOGS_CAP = 6 * 2**30                    # 6 GiB, hard cap, 10 GB disk
LOGS_ALERT = 5.5e9                      # rules/logs.yml LogsNearDiskCap
TRACES_CAP = 16 * 2**30                 # 16 GiB, hard cap, 20 GB disk
TRACES_ALERT = 15569256448              # rules/traces.yml TracesNearDiskCap, 14.5 GiB

# The stores' alert-style "up": scrape works and the health URL answers. A series
# that has disappeared reads 0 (DOWN), not "n/a".
def healthy(instance: str, scrape: str) -> str:
    return (f'(min(up{{{scrape}}}) * '
            f'min(probe_success{{job="blackbox_http", instance="{instance}"}})) or vector(0)')


def boards():
    b = board(
        uid="homelab-obs-stores", title="Log and trace stores", folder="Observability",
        description="Are VictoriaLogs (CT 121) and VictoriaTraces (CT 122) taking data in and "
                    "keeping it for 30 days? Open it when a Logs or Traces alert fires, when a "
                    "board's logs or traces panel is empty, and weekly to see how much of "
                    "each disk cap is used.",
        method="use", filename="stores",
    )

    # -- the answer -------------------------------------------------------------
    b.row("Are the stores taking data in?", [
        up_stat(
            "Logs: up", healthy("logs", VL), w=3,
            desc="VictoriaLogs answers its health URL and its /metrics scrape works. DOWN means "
                 "no log is stored and Explore shows nothing (rule HttpProbeFailed: warning "
                 "after 5 minutes for a standard-tier host; rule TargetDown for the scrape). "
                 "The senders keep a cursor and catch up after an outage."),
        stat(
            "Logs: ingest rows/s",
            f'sum(rate(vl_rows_ingested_total{{{VL}}}[$__rate_interval]))',
            unit="ops", decimals=2, w=3,
            thresholds=steps(("red", None), ("green", 1e-6)),
            desc="Log lines stored per second, from every node, guest and the hEX. Red at zero "
                 "mirrors rule LogsIngestionStopped (a 15-minute rate that stays zero for 15 "
                 "minutes, warning): this tile uses a shorter window, so it turns red first. "
                 "Every host ships continuously, so zero means shipping is broken."),
        stat(
            "Logs: stored of cap",
            f'sum(vl_data_size_bytes{{{VL}}}) / max(vl_max_disk_space_usage_bytes{{{VL}}})',
            unit="percentunit", decimals=1, w=3,
            thresholds=steps(("green", None), ("red", LOGS_ALERT / LOGS_CAP)),
            desc="Log data on disk as a share of the 6 GiB hard cap. Red from 5.5e9 bytes is rule "
                 "LogsNearDiskCap (info, after 1 hour): the oldest days are dropped before the "
                 "30-day retention."),
        problem_stat(
            "Logs: rows dropped, 1 h",
            f'sum(increase(vl_rows_dropped_total{{{VL}, reason!="too_small_timestamp"}}[1h]))',
            warn_only=True, w=3,
            desc="Rows VictoriaLogs refused in the last hour, without the `too_small_timestamp` "
                 "reason: lines older than the 30-day retention are dropped at ingest by design "
                 "(a sender replaying its whole journal), so those are not counted. What is left "
                 "is real: too many fields, a timestamp in the future, debug. No alert mirrors it."),
        up_stat(
            "Traces: up", healthy("traces", VT), w=3,
            desc="VictoriaTraces answers its health URL and its /metrics scrape works. DOWN "
                 "means spans are refused and the Traces data source shows nothing (rule "
                 "HttpProbeFailed: warning after 5 minutes for a standard-tier host; rule "
                 "TargetDown for the scrape). Nothing sends traces yet, so down costs no data today."),
        stat(
            "Traces: stored of cap",
            f'sum(vt_data_size_bytes{{{VT}}}) / max(vt_max_disk_space_usage_bytes{{{VT}}})',
            unit="percentunit", decimals=2, w=3,
            thresholds=steps(("green", None), ("red", TRACES_ALERT / TRACES_CAP)),
            desc="Trace data on disk as a share of the 16 GiB hard cap. Red from 14.5 GiB is rule "
                 "TracesNearDiskCap (info, after 1 hour). It reads about 0 % today: no app sends "
                 "traces yet, only the 6 rows of the smoke test are stored."),
        problem_stat(
            "Traces: rows dropped, 1 h",
            f'sum(increase(vt_rows_dropped_total{{{VT}, reason!="too_small_timestamp"}}[1h]))',
            warn_only=True, w=3,
            desc="Spans VictoriaTraces refused in the last hour (too many fields, a timestamp in "
                 "the future, debug; spans older than retention are expected and not counted). "
                 "Zero today because nothing sends. No alert mirrors it."),
        problem_stat(
            "Stores read-only",
            f'max(vl_storage_is_read_only{{{VL}}} or vt_storage_is_read_only{{{VT}}})',
            w=3,
            desc="1 when either store has put itself in read-only mode and rejects writes, which a "
                 "store does when its disk is nearly full. Should be 0. No alert mirrors it: "
                 "LogsNearDiskCap and TracesNearDiskCap fire earlier, at the retention cap."),
    ])

    # -- VictoriaLogs: ingest ------------------------------------------------------
    b.row("VictoriaLogs (CT 121): what comes in", [
        timeseries(
            "Logs: rows ingested, by source",
            [(f'sum by (type) (rate(vl_rows_ingested_total{{{VL}}}[$__rate_interval]))', "{{type}}")],
            desc="Log lines stored per second: `journald` from the nodes and guests "
                 "(systemd-journal-upload), `syslog_udp` from the hEX. Both should be steady "
                 "above zero: a source that goes flat is shipping broken (rule "
                 "LogsIngestionStopped fires only when the total is zero).",
            unit="ops", w=6, h=8),
        timeseries(
            "Logs: rows dropped in the last hour, by reason",
            [(f'sum by (reason) (increase(vl_rows_dropped_total{{{VL}}}[1h]))', "{{reason}}")],
            desc="Rows refused, counted over a trailing hour. `too_small_timestamp` is expected: "
                 "a sender that replays its journal sends lines older than the 30-day "
                 "retention. `too_many_fields`, `too_big_timestamp` and `debug` are real: a "
                 "sender with a broken clock or a runaway field set. No alert mirrors it.",
            unit="short", w=6, h=8),
        timeseries(
            "Logs: HTTP requests and errors",
            [(f'sum by (path) (rate(vl_http_requests_total{{{VL}}}[$__rate_interval])) > 0',
              "{{path}} requests"),
             (f'sum(rate(vl_http_errors_total{{{VL}}}[$__rate_interval]))', "errors, all paths")],
            desc="RED for the store's HTTP API: requests per second by path (only paths with "
                 "traffic are drawn; the journald upload carries nearly all of it) and the "
                 "error rate. A rising error line is senders getting rejected. No alert "
                 "mirrors it.",
            unit="reqps", w=6, h=8),
        timeseries(
            "Logs: journald upload latency",
            [(f'vl_http_request_duration_seconds{{{VL}, path="/insert/journald/upload", '
              'quantile=~"0.5|0.99"}', "p{{quantile}}")],
            desc="How long VictoriaLogs takes to answer a journald upload (a summary exported by "
                 "the store: the median and the 99th percentile of its recent requests). "
                 "Milliseconds is normal; seconds means the disk or CPU of CT 121 is "
                 "saturated. No alert mirrors it.",
            unit="s", w=6, h=8),
    ])

    # -- disk and retention --------------------------------------------------------
    b.row("Disk and retention", [
        timeseries(
            "Logs: stored against the cap",
            [(f'sum(vl_data_size_bytes{{{VL}}})', "stored (data + index)"),
             (f'max(vl_max_disk_space_usage_bytes{{{VL}}})', "hard cap")],
            desc="Log data on disk against the 6 GiB hard cap. The dashed line is 5.5e9 bytes, "
                 "rule LogsNearDiskCap (info, after 1 hour): above it the oldest days are dropped "
                 "before the 30-day retention. Compressed logs are small: far below the cap is "
                 "the normal state.",
            unit="bytes", w=8, h=8,
            thresholds=steps(("green", None), ("red", LOGS_ALERT)), threshold_style="dashed"),
        timeseries(
            "Logs: oldest log kept",
            [(f'(time() - vl_storage_log_min_timestamp_seconds{{{VL}}}) / 86400', "oldest log")],
            desc="Age of the oldest stored log line, in days. It climbs to the 30-day retention "
                 "(dashed) and stays there. If it stops short of 30 while the stored size is "
                 "near the cap, the cap is cutting retention short (rule LogsNearDiskCap).",
            unit="d", w=8, h=8, legend="hidden",
            thresholds=steps(("green", None), ("red", 30)), threshold_style="dashed"),
        timeseries(
            "Free disk space, logs and traces",
            [(f'max(vl_free_disk_space_bytes{{{VL}}})', "logs (CT 121, 10 GB disk)"),
             (f'max(vt_free_disk_space_bytes{{{VT}}})', "traces (CT 122, 20 GB disk)")],
            desc="Free bytes on each store's data disk. The hard caps (6 GiB, 16 GiB) leave room "
                 "on the 10 GB and 20 GB disks; a free-space line that falls toward zero with "
                 "the stored size far below its cap means something else is filling the CT. "
                 "No alert mirrors it (HostFilesystemFull covers nodes and the monitoring CT).",
            unit="bytes", w=8, h=8),
    ])

    # -- VictoriaTraces ------------------------------------------------------------
    b.row("VictoriaTraces (CT 122): what comes in and what is kept", [
        timeseries(
            "Traces: ingest, rows and requests per second",
            [(f'sum by (type) (rate(vt_rows_ingested_total{{{VT}}}[$__rate_interval]))',
              "rows {{type}}"),
             (f'sum(rate(vt_http_requests_total{{{VT}, path=~"/insert/.*|/opentelemetry.*"}}'
              '[$__rate_interval]))', "insert requests"),
             (f'sum(rate(vt_http_errors_total{{{VT}}}[$__rate_interval]))', "errors, all paths")],
            desc="Spans stored per second, insert requests per second and request errors. No "
                 "app sends traces yet, so the rows series does not exist (vt_rows_ingested_total "
                 "appears with the first span) and the request lines sit at zero: that is "
                 "expected. Once a sender exists, a flat line while it runs means spans are "
                 "refused. No alert mirrors it.",
            unit="ops", w=8, h=8, empty_ok=True),
        timeseries(
            "Traces: rows dropped in the last hour, by reason",
            [(f'sum by (reason) (increase(vt_rows_dropped_total{{{VT}}}[1h]))', "{{reason}}")],
            desc="Spans refused, over a trailing hour: `too_many_fields`, `too_big_timestamp`, "
                 "`too_small_timestamp` (older than retention), `debug`. All zero until an app "
                 "sends. No alert mirrors it.",
            unit="short", w=8, h=8),
        timeseries(
            "Traces: stored against the cap",
            [(f'sum(vt_data_size_bytes{{{VT}}})', "stored (data + index)"),
             (f'max(vt_max_disk_space_usage_bytes{{{VT}}})', "hard cap")],
            desc="Trace data on disk against the 16 GiB hard cap. The dashed line is 14.5 GiB, "
                 "rule TracesNearDiskCap (info, after 1 hour): above it the oldest days are "
                 "dropped before the 30-day retention. A few KB today: only the smoke-test "
                 "span is stored.",
            unit="bytes", w=8, h=8,
            thresholds=steps(("green", None), ("red", TRACES_ALERT)), threshold_style="dashed"),
    ])

    # -- process resources (USE) ---------------------------------------------------
    b.row("The two processes (USE)", [
        timeseries(
            "Stores: CPU, share of one core",
            [(f'rate(process_cpu_seconds_total{{{BOTH}}}[$__rate_interval])', "{{instance}}")],
            desc="CPU each store process uses, as a share of one core (both CTs have one core). "
                 "Near 100 % for long means ingest or queries are CPU-bound and uploads slow "
                 "down. Idle stores sit near zero. No alert mirrors it.",
            unit="percentunit", w=6, h=8),
        timeseries(
            "Stores: resident memory",
            [(f'process_resident_memory_bytes{{{BOTH}}}', "{{instance}}")],
            desc="Memory each store process holds. CT 121 has 512 MiB of RAM and CT 122 has "
                 "1 GiB (proxmox/opentofu/logs.tf, traces.tf): the process's own memory-limit "
                 "metric reports the host's RAM seen through the CT, so no limit line is drawn. "
                 "A line that climbs toward its CT's RAM ends in an out-of-memory kill. No "
                 "alert mirrors it.",
            unit="bytes", w=6, h=8),
        timeseries(
            "Stores: insert concurrency limit reached",
            [(f'sum by (instance) (increase(vm_concurrent_insert_limit_reached_total{{{BOTH}}}'
              '[$__rate_interval]))', "{{instance}}")],
            desc="Times an insert had to wait because every insert slot was busy (the store's "
                 "concurrency limit). Occasional ones are fine; a steady stream means senders "
                 "are queueing behind a saturated store. No alert mirrors it.",
            unit="short", w=6, h=8),
        timeseries(
            "Stores: rows pending",
            [(f'sum by (instance) (vl_pending_rows{{{VL}}})', "{{instance}}"),
             (f'sum by (instance) (vt_pending_rows{{{VT}}})', "{{instance}}")],
            desc="Rows accepted but not yet searchable: a store buffers them for a few seconds "
                 "before they are queryable (the smoke test waits for this). A number that "
                 "keeps rising instead of returning to zero means the store cannot flush as fast "
                 "as rows arrive. Zero for the trace store while nothing sends. No alert "
                 "mirrors it.",
            unit="short", w=6, h=8),
    ], collapsed=True)

    # -- the stores' own errors ----------------------------------------------------
    b.row("The stores' own warnings and errors", [
        timeseries(
            "Stores: warnings and errors logged, by level",
            [(f'sum by (instance, level) (increase(vm_log_messages_total{{{BOTH}, level!="info"}}'
              '[$__rate_interval]))', "{{instance}} {{level}}")],
            desc="Lines the two store processes logged above info level, counted from their own "
                 "metrics, which works even when log shipping is down. A few warnings at "
                 "start-up are normal; a steady stream of errors means look at the lines "
                 "below. No alert mirrors it.",
            unit="short", w=24, h=6),
        logs(
            "Stores: errors in their own logs",
            '_stream:{_HOSTNAME=~"logs|traces"} level:(error or critical)',
            desc="Error and critical lines from CT 121 and CT 122 (VictoriaLogs ships its own "
                 "journal to itself, so this panel is empty when the log store is down: use "
                 "the metrics panel above then). Empty is good. Not checked by "
                 "--verify-live.",
            w=24, h=10),
    ])
    return [b]
