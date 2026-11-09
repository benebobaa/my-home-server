"""Valkey: "are the shared Valkey instances up, in memory budget, fast, and are their apps
getting what they ask for?" Two instances in CT 132, one per app (job service, instance
valkey; one redis_exporter each, the `port` label is the exporter's: 9121 is Kubeletto's
instance on :6380, 9122 is larasrouter's on :6381, valkey_instances in
proxmox/opentofu/valkey.tf). Both run volatile-lru, 96 MB and 64 MB maxmemory.

Top row = the answer (8 stats). Mirrored rules, in services/monitoring/prometheus/rules/
app-valkey.yml: ValkeyDown, ValkeyMemoryFull. The exporter itself down is TargetDown
(rules/meta.yml). Below, one row per question: memory (utilisation and saturation),
traffic and latency (rate, errors, duration), clients, keyspace and persistence, the
server log.

Sources: the queries are derived from the live metric names on the lab's Prometheus, from
the alert rules above, and from the previous app-valkey board's queries (git history,
0b2d5b6:services/monitoring/grafana/dashboards/app-valkey.json), each re-checked against
live data. No upstream mixin or vendor dashboard was consulted.

Facts that shaped the queries (checked against the live data):
- Valkey reports its version as 7.2.4 (the Redis-compatible number); metric names are
  redis_*.
- The exporter's own commands (AUTH, CLIENT SETNAME, CONFIG GET, INFO, LATENCY HISTOGRAM and
  LATENCY LATEST, SLOWLOG GET and LEN) run once per scrape on every instance. On the
  quiet Kubeletto instance they are more than half of all commands (120 calls an hour
  each against about 400 app calls), so every rate and latency panel excludes them with
  EXPORTER_CMDS. The CONFIG GET and INFO calls alone take about 0.3-1 ms.
- redis_commands_latencies_usec_bucket is sparse: a command's buckets appear only once
  they hold a sample. `sum by (le)` across commands therefore mixes cumulative series that
  are missing different buckets and the result is not cumulative (checked: the 9121 buckets
  fell from 0.207 at le=33 to 0.141 at le=66), so histogram_quantile over all commands read
  4.2 and 8.5 ms p99 while every command's own summary says under 150 us. The p99 panel
  therefore takes one command at a time (sum by (port, cmd, le)), and the mean command time
  (redis_commands_duration_seconds_total over redis_commands_total) is the exact all-
  commands number.
- The keyspace is tiny and short-lived (at most 11 keys in 7 days, 0 at this moment): rate
  limits, locks and cache entries with TTLs; redis_db_keys can read 0.
- Persistence is effectively off: no RDB save has run since the process started
  (changes since last save grows without bound, bgsave duration -1), AOF is off. The
  runbook calls these instances data-less, rebuildable: by design, not a finding.
- redis_mem_fragmentation_ratio reads about 11: an artefact of 1.4 MB used on a 15 MB
  resident process, not fragmentation; no panel uses it.
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, table, logs, var_query,
    steps,
)

V = 'job="service", instance="valkey", port=~"$port"'
# The exporter runs these on every scrape (see the module docstring); `\\|` is a literal
# pipe in a PromQL string.
EXPORTER_CMDS = r'cmd!~"info|config\\|get|latency\\|.*|slowlog\\|.*|auth|client\\|.*"'
# One command at a time for the p99 panel: the sparse histogram buckets cannot be summed
# across commands.
APP_CMDS = 'cmd=~"get|set|del|eval|evalsha"'

MEM_SHARE = (f'redis_memory_used_bytes{{{V}}} / (redis_memory_max_bytes{{{V}}} > 0)')


def _line_at(value: float) -> dict:
    """A dashed boundary line is drawn in the colour of the step that starts there."""
    return steps(("green", None), ("red", value))


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def by_instance(expr: str) -> str:
    """One row per instance with its app port and eviction policy attached, so the
    persistence table's targets merge."""
    info = ('max by (port, tcp_port, maxmemory_policy) (redis_instance_info{' + V + '})')
    return ('max by (port, tcp_port, maxmemory_policy) ((' + expr + ')'
            ' * on (port) group_left (tcp_port, maxmemory_policy) ' + info + ')')


def boards():
    b = board(
        uid="homelab-platform-valkey", title="Valkey", folder="Platform services",
        description="Are the shared Valkey instances (CT 132, one per app) up, inside their "
                    "memory budget and fast, and is each app getting hits? Open it after a "
                    "Valkey* alert, when an app reports cache, lock or rate-limit errors, and "
                    "weekly to see memory headroom.",
        method="use", filename="valkey",
        variables=[var_query("port", "Instance (exporter port)",
                             'label_values(redis_up{job="service", instance="valkey"}, port)',
                             multi=True, include_all=True)],
    )

    # ---- the answer ----------------------------------------------------------------
    b.row("Is Valkey OK?", [
        up_stat(  # ValkeyDown
            "Instances up", f'min(redis_up{{{V}}}) or vector(0)', w=3,
            desc="Every selected instance answers its exporter (redis_up; rule ValkeyDown: 0 "
                 "for 2 minutes, severity from the host's tier, critical today). DOWN means "
                 "an app has no cache, locks or rate limits (Kubeletto's core refuses to start "
                 "without it). Also DOWN when the exporter itself is gone (rule TargetDown). "
                 "Next: 'systemctl status valkey-server@<app>' in CT 132 and the Server log row."),
        stat(  # ValkeyMemoryFull
            "Memory of maxmemory, fullest", f'max({MEM_SHARE})', unit="percentunit",
            decimals=1, w=3, thresholds=_line_at(0.95),
            desc="The fullest selected instance's used memory over its maxmemory. Red from 95 % "
                 "is rule ValkeyMemoryFull (15 minutes). Full is normal for a cache that "
                 "evicts; with volatile-lru it is not when the keys without a TTL fill the "
                 "cap, and writes then fail with OOM. Near 1-2 % today."),
        problem_stat(
            "Evictions, 1 h", f'sum(increase(redis_evicted_keys_total{{{V}}}[1h]))',
            warn_only=True, w=3,
            desc="Keys Valkey deleted to make room (maxmemory reached) in the last hour. 0 is "
                 "healthy here: instances are far below their cap. A cache that evicts is "
                 "working as designed; for locks or rate limits an eviction means a lost key. "
                 "No alert mirrors it: ValkeyMemoryFull fires before it matters."),
        stat(
            "Hit ratio, 1 h",
            f'sum(increase(redis_keyspace_hits_total{{{V}}}[1h]))'
            f' / (sum(increase(redis_keyspace_hits_total{{{V}}}[1h]))'
            f' + sum(increase(redis_keyspace_misses_total{{{V}}}[1h])) > 0)',
            unit="percentunit", decimals=1, w=3, thresholds=steps(("orange", None), ("green", 0.5)),
            desc="Share of key lookups that found the key, over the last hour, for the "
                 "selected instances together. For a cache a low ratio means it saves little; "
                 "for locks and rate limits a miss is part of the protocol, so read it per "
                 "instance in the Traffic row. n/a when nothing was looked up. No alert rule."),
        stat(
            "Clients connected", f'sum(redis_connected_clients{{{V}}})', unit="short", w=3,
            graph=True, color_mode="value",
            desc="Open client connections on the selected instances (the exporter holds one "
                 "per instance). The limit is 10000 each, so this is a sign of pool size, "
                 "not saturation; a number that climbs without a matching load is an app "
                 "leaking connections. No alert rule."),
        problem_stat(
            "Blocked clients", f'sum(redis_blocked_clients{{{V}}})', warn_only=True, w=3,
            desc="Clients waiting on a blocking command (BLPOP and friends). Should be 0: nothing "
                 "here issues blocking commands (the commands seen are GET, SET, EVAL, DEL, "
                 "INCR and sorted-set calls), so a blocked client is unexpected. No alert rule."),
        problem_stat(
            "Connections rejected, 1 h",
            f'sum(increase(redis_rejected_connections_total{{{V}}}[1h]))', w=3,
            desc="Connections refused because maxclients (10000) was reached, in the last hour. "
                 "Should be 0 (it is 0 since the instances started). Red at 1 or more means a runaway client. "
                 "No alert rule."),
        problem_stat(
            "Error replies, 1 h", f'sum(increase(redis_total_error_replies{{{V}}}[1h]))',
            warn_only=True, w=3,
            desc="Commands that returned an error in the last hour (wrong type, NOSCRIPT, "
                 "OOM, permission). A handful is normal: a client asking for a script that "
                 "was flushed gets NOSCRIPT and loads it. A steady stream is an app bug or "
                 "the instance refusing writes. No alert mirrors it."),
    ])

    # ---- memory (USE) --------------------------------------------------------------
    b.row("Memory: utilisation and saturation", [
        timeseries(
            "Memory used, share of maxmemory",
            [(MEM_SHARE, "{{port}}")],
            desc="Used memory over maxmemory for each selected instance (9121 is Kubeletto's, "
                 "96 MB; 9122 is larasrouter's, 64 MB). The dashed line is 95 %, rule "
                 "ValkeyMemoryFull (15 minutes). With volatile-lru only keys that have a TTL "
                 "are evicted: a line that climbs to the dashed one means keys without a TTL "
                 "fill the cap and writes will fail with OOM.",
            unit="percentunit", max=1, decimals=1, w=8, h=8,
            thresholds=_line_at(0.95), threshold_style="dashed"),
        timeseries(
            "Memory used and resident",
            [(f'redis_memory_used_bytes{{{V}}}', "{{port}} used"),
             (f'redis_memory_used_rss_bytes{{{V}}}', "{{port}} resident (RSS)")],
            desc="Bytes Valkey has allocated for data (used) and the process's resident set as "
                 "the OS sees it. Used drives eviction and ValkeyMemoryFull; resident is what "
                 "CT 132's 256 MB must hold for both instances plus the exporters. Resident is "
                 "mostly the fixed cost of the process at this small data size: the gap is "
                 "not fragmentation. No alert rule.",
            unit="bytes", w=8, h=8),
        timeseries(
            "Evicted and expired keys per second",
            [(f'sum by (port) (rate(redis_evicted_keys_total{{{V}}}[$__rate_interval]))', "{{port}} evicted"),
             (f'sum by (port) (rate(redis_expired_keys_total{{{V}}}[$__rate_interval]))', "{{port}} expired")],
            desc="Keys removed because memory ran out (evicted) and because their TTL ran out "
                 "(expired, the normal lifecycle). Evicted should stay 0 while instances "
                 "sit far below maxmemory; expired follows the apps' TTLs. No alert rule.",
            unit="ops", decimals=3, w=8, h=8),
    ])

    # ---- traffic and latency (RED) -------------------------------------------------
    b.row("Traffic and latency: rate, errors, duration", [
        timeseries(
            "Commands per second",
            [(f'sum by (port) (rate(redis_commands_total{{{V}, {EXPORTER_CMDS}}}[$__rate_interval]))',
              "{{port}}")],
            desc="Commands the apps run per second on each instance, without the exporter's "
                 "own scrape commands (INFO, CONFIG GET, LATENCY and SLOWLOG calls, about 0.27 "
                 "a second per instance, which would otherwise be most of the quiet "
                 "instance's traffic). Its PING (one per scrape) cannot be told from an app's "
                 "and stays in. A flat zero while the app runs means it cannot reach "
                 "Valkey. No alert rule.",
            unit="ops", decimals=2, w=8, h=8),
        timeseries(
            "Mean command time",
            [(f'sum by (port) (rate(redis_commands_duration_seconds_total{{{V}, {EXPORTER_CMDS}}}[$__rate_interval]))'
              f' / (sum by (port) (rate(redis_commands_total{{{V}, {EXPORTER_CMDS}}}[$__rate_interval])) > 0)',
              "{{port}}")],
            desc="Time Valkey spends executing an average application command, from its own "
                 "duration counter (queueing and the network are not included). Tens to a "
                 "hundred microseconds is normal here (Lua scripts cost most); a line that "
                 "climbs to milliseconds means a slow command (see the p99 panel), a big "
                 "key or a CPU-starved CT. A gap is a window with no commands. No alert rule.",
            unit="s", decimals=6, w=8, h=8),
        timeseries(
            "p99 latency, per command",
            [(f'histogram_quantile(0.99, sum by (port, cmd, le) (rate(redis_commands_latencies_usec_bucket{{{V}, {APP_CMDS}}}'
              '[$__rate_interval])))', "{{port}} {{cmd}}")],
            desc="99th percentile of each main command's latency, from Valkey's latency "
                 "histogram, per instance. With a few calls per window it is close to the "
                 "slowest call: single-digit microseconds for GET, SET and DEL, about a "
                 "hundred for EVAL (Lua). Taken per command because the histogram cannot be "
                 "summed across commands (its buckets are sparse). A gap is a command that "
                 "did not run in the window. No alert rule.",
            unit="µs", w=8, h=8, legend="table", legend_calcs=("mean", "max")),
        timeseries(
            "Keyspace hit ratio, by instance",
            [(f'sum by (port) (rate(redis_keyspace_hits_total{{{V}}}[$__rate_interval]))'
              f' / (sum by (port) (rate(redis_keyspace_hits_total{{{V}}}[$__rate_interval]))'
              f' + sum by (port) (rate(redis_keyspace_misses_total{{{V}}}[$__rate_interval])) > 0)',
              "{{port}}")],
            desc="Share of key lookups that found the key, per instance. Read it against what "
                 "the instance is for: larasrouter's reads almost always hit; Kubeletto's runs "
                 "lower (about 80 % since the instance started). A "
                 "sudden fall for a cache is a flush or a TTL set too short. A gap is a "
                 "window with no lookups. No alert rule.",
            unit="percentunit", max=1, decimals=1, w=8, h=8),
        timeseries(
            "Failed and rejected commands per second",
            [(f'sum by (port) (rate(redis_commands_failed_calls_total{{{V}}}[$__rate_interval]))',
              "{{port}} failed"),
             (f'sum by (port) (rate(redis_commands_rejected_calls_total{{{V}}}[$__rate_interval]))',
              "{{port}} rejected")],
            desc="Failed = the command ran and returned an error (NOSCRIPT after a script "
                 "flush, a wrong key type). Rejected = refused before running (OOM when "
                 "maxmemory is full of non-evictable keys, a permission error). Failed at "
                 "a trickle is normal; rejected above 0 is the real symptom of "
                 "ValkeyMemoryFull. No alert rule.",
            unit="ops", decimals=3, w=8, h=8),
    ])

    # ---- clients, keyspace, persistence --------------------------------------------
    b.row("Clients, keyspace and persistence", [
        timeseries(
            "Clients connected and blocked",
            [(f'sum by (port) (redis_connected_clients{{{V}}})', "{{port}} connected"),
             (f'sum by (port) (redis_blocked_clients{{{V}}})', "{{port}} blocked")],
            desc="Open connections per instance (limit 10000) and clients stuck in a blocking "
                 "call. Connected tracks the apps' pool sizes: a steady number is normal, a "
                 "ramp with no extra load is a leak. Blocked should be 0. No alert rule.",
            unit="short", w=8, h=7),
        timeseries(
            "New and rejected connections per second",
            [(f'sum by (port) (rate(redis_connections_received_total{{{V}}}[$__rate_interval]))',
              "{{port}} accepted"),
             (f'sum by (port) (rate(redis_rejected_connections_total{{{V}}}[$__rate_interval]))',
              "{{port}} rejected")],
            desc="Connections opened per second (the exporter opens one per scrape, 0.03 a "
                 "second) and connections refused at maxclients. A high accepted rate means "
                 "clients connect per request instead of pooling. Rejected should be 0. "
                 "No alert rule.",
            unit="ops", decimals=3, w=8, h=7),
        timeseries(
            "Keys, and keys without a TTL",
            [(f'sum by (port) (redis_db_keys{{{V}}})', "{{port}} keys"),
             (f'sum by (port) (redis_db_keys{{{V}}}) - sum by (port) (redis_db_keys_expiring{{{V}}})',
              "{{port}} without a TTL")],
            desc="Keys in all databases and how many of them never expire. The keyspace is "
                 "tiny and short-lived here (single digits, up to 11 in a week), so 0 is "
                 "common. Keys without a TTL are the ones volatile-lru cannot evict: many of "
                 "them is how ValkeyMemoryFull happens. No alert rule.",
            unit="short", w=8, h=7),
        table(
            "Instances and persistence",
            [(by_instance(f'redis_memory_used_bytes{{{V}}}'), ""),
             (by_instance(f'redis_memory_max_bytes{{{V}}}'), ""),
             (by_instance(f'redis_rdb_last_bgsave_status{{{V}}}'), ""),
             (by_instance(f'redis_aof_enabled{{{V}}}'), ""),
             (by_instance(f'redis_rdb_changes_since_last_save{{{V}}}'), ""),
             (by_instance(f'redis_uptime_in_seconds{{{V}}}'), "")],
            desc="One row per instance: which port it listens on, its eviction policy, memory "
                 "used and maxmemory, whether the last RDB save succeeded, whether AOF is on, "
                 "writes since the last save, and uptime. Persistence is off by design: changes "
                 "since the last save only grows and AOF is off, because the instances hold "
                 "no data that cannot be rebuilt (a CT rebuild is always safe). Uptime resets "
                 "to 0 at a restart.",
            columns=[("port", "Exporter"), ("tcp_port", "Valkey port"),
                     ("maxmemory_policy", "Eviction policy"),
                     ("Value #A", "Memory used"), ("Value #B", "maxmemory"),
                     ("Value #C", "Last save"), ("Value #D", "AOF"),
                     ("Value #E", "Writes since save"), ("Value #F", "Uptime")],
            overrides=[
                _col("Memory used", ("unit", "bytes")),
                _col("maxmemory", ("unit", "bytes")),
                _col("Uptime", ("unit", "s")),
                _col("Last save", ("mappings", [{"type": "value", "options": {
                    "0": {"text": "FAILED", "color": "red", "index": 0},
                    "1": {"text": "ok", "color": "green", "index": 1}}}]),
                     ("custom.cellOptions", {"type": "color-text"})),
                _col("AOF", ("mappings", [{"type": "value", "options": {
                    "0": {"text": "off", "index": 0},
                    "1": {"text": "on", "index": 1}}}])),
            ],
            sort_by="Exporter", descending=False, w=24, h=6),
    ])

    # ---- the server's own log ------------------------------------------------------
    b.row("Server log", [
        logs(
            "Valkey: errors and warnings",
            '_stream:{_HOSTNAME="valkey"} (level:(error or critical or warning) or error or OOM)',
            desc="Lines from CT 132's journal (valkey-server@<app> units) that the journal "
                 "marks warning or worse, or that mention an error or an out-of-memory "
                 "refusal. Start-up notes (RDB load, 'Ready to accept connections') are "
                 "normal and are not shown; a refusal or repeated warnings are the story "
                 "behind a ValkeyMemoryFull or ValkeyDown. Not checked by --verify-live.",
            w=24, h=10),
    ])
    return [b]
