"""PostgreSQL: "is the shared Postgres up, healthy, not filling its disk, and is its
off-site copy current?" The one Postgres 18 in CT 130 (job service, instance postgres:
postgres_exporter on :9187, and the CT's node_exporter on :9100, which carries only the
off-site textfile series).

Top row = the answer, one tile per rule that can sit in a tile (same thresholds as the
rules in services/monitoring/prometheus/rules/app-postgres.yml): PostgresDown,
PostgresConnectionsHigh, PostgresDiskFilling, PostgresDatabaseLarge,
PostgresDatabaseGrowingFast, PostgresOffsiteArchiveStale, PostgresOffsiteFullBackupOld,
PostgresOffsiteRepoLarge. PostgresOffsiteDailyFailing and PostgresOffsiteGuardExpired are
tiles of the off-site row. Below, one row per question: saturation (connections, locks,
long transactions), health (transactions, cache, rows, temp files, deadlocks, WAL), size
and growth, the CT's disk, the off-site copy, and the server log. Down at the TargetDown
level (the exporter itself) is rules/meta.yml.

Sources: the queries are derived from the live metric names on the lab's Prometheus, from
the alert rules above, and from the previous app-postgres board's queries (git history,
0b2d5b6:services/monitoring/grafana/dashboards/app-postgres.json), each re-checked against
live data. No upstream mixin or vendor dashboard was consulted.

Facts that shaped the queries (checked against the live data):
- The `port` label on the pg_* series was added on 2026-11-09 (metrics now come from two
  ports); the old series, without it, ended an hour earlier. delta() or a range over the
  change therefore returns two series per database for a week. Every size and growth query
  wraps the series in `max by (datname)`, which stitches the two into one line (the
  growth queries subtract the value at `offset` instead of using delta()).
- CT 130's node_exporter runs the textfile collector only: no node_filesystem_*, no CPU.
  The disk is the Proxmox view, exactly as the PostgresDiskFilling rule reads it
  (pve_disk_* joined to pve_guest_info{name="postgres"}; every pve_* series carries
  instance="pve2").
- The off-site series (pg_offsite_*) exist and are fresh (archiving is live). If they
  vanish the alerts go silent, so their panels are not empty_ok.
- Not exported by this postgres_exporter (a data gap): checkpoint and WAL-byte counters
  (the bgwriter collector only has buffers_*; PG 18 moved checkpoints to
  pg_stat_checkpointer), waiting locks (pg_locks_count counts locks held, per mode),
  per-table sizes and dead tuples (pg_stat_user_tables_* has no series), per-query timing.
  There is no replica, so there is no replication lag panel (pg_replication_is_replica = 0).
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, logs,
    steps, lo_bad,
)

PG = 'job="service", instance="postgres"'
# PostgresDatabaseLarge / GrowingFast leave the system databases out; the other panels
# show the postgres database too, but never the templates.
APPDB = 'datname!~"postgres|template.*"'
ALLDB = 'datname!~"template.*"'
OFFSITE = 'job="service", instance="postgres"'

# CT 130's root disk, exactly as PostgresDiskFilling reads it.
ROOT_DISK = ('(pve_disk_usage_bytes / pve_disk_size_bytes)'
             ' * on (id) group_left (name) pve_guest_info{name="postgres"}')
# Days until the disk is full if the last 7 days continue (nodes.py RUNWAY's shape, capped
# at a year; a disk that is not growing reads 365).
RUNWAY = ('clamp_max(((pve_disk_size_bytes - pve_disk_usage_bytes)'
          ' / clamp_min(deriv(pve_disk_usage_bytes[7d]), 1) / 86400)'
          ' * on (id) group_left (name) pve_guest_info{name="postgres"}, 365)')

SIZE = f'max by (datname) (pg_database_size_bytes{{{PG}, {ALLDB}}})'
SIZE_APP = f'max by (datname) (pg_database_size_bytes{{{PG}, {APPDB}}})'
GROW_1D = f'{SIZE_APP} - max by (datname) (pg_database_size_bytes{{{PG}, {APPDB}}} offset 1d)'
GROW_7D = f'{SIZE_APP} - max by (datname) (pg_database_size_bytes{{{PG}, {APPDB}}} offset 7d)'

GB = 1e9  # B2 and the rules count decimal gigabytes


def _line_at(value: float) -> dict:
    """A dashed boundary line is drawn in the colour of the step that starts there."""
    return steps(("green", None), ("red", value))


def boards():
    b = board(
        uid="homelab-platform-postgres", title="PostgreSQL", folder="Platform services",
        description="Is the shared PostgreSQL (CT 130) up, healthy and not filling its disk, and "
                    "is its off-site copy on Backblaze B2 current? Open it after a Postgres* "
                    "alert, when an app reports database errors, and weekly to see growth and "
                    "the off-site repo size.",
        method="use", filename="postgres", time_from="now-24h",
    )

    # ---- the answer ----------------------------------------------------------------
    b.row("Is PostgreSQL OK?", [
        up_stat(  # PostgresDown
            "PostgreSQL up", f'min(pg_up{{{PG}}}) or vector(0)', w=3,
            desc="The exporter can run a query on the server (pg_up; rule PostgresDown: 0 for "
                 "2 minutes, severity from the host's tier, critical today). DOWN means every app "
                 "with a database is failing. Also DOWN when the exporter itself is gone (rule "
                 "TargetDown). Next: the Server log row, then 'systemctl status "
                 "postgresql@18-main' in CT 130 (runbook PostgresDown)."),
        stat(  # PostgresConnectionsHigh
            "Connections in use",
            f'sum(pg_stat_activity_count{{{PG}}}) / max(pg_settings_max_connections{{{PG}}})',
            unit="percentunit", decimals=0, w=3, thresholds=_line_at(0.8),
            desc="Backends of every state over max_connections (100). Red from 80 % is rule "
                 "PostgresConnectionsHigh (10 minutes): new connections are refused soon, almost "
                 "always an app leaking connections or a pool set too large. The Connections "
                 "panel names who holds them."),
        stat(  # PostgresDiskFilling
            "Root disk used", f'max({ROOT_DISK})', unit="percentunit", decimals=0, w=3,
            thresholds=_line_at(0.8),
            desc="CT 130's root disk, from the Proxmox API (data, WAL, the last 3 dumps all live "
                 "there). Red from 80 % is rule PostgresDiskFilling (30 minutes); at 100 % every "
                 "write fails. The CT's node_exporter has no filesystem collector, so this is the "
                 "only disk series. The Disk row shows the runway."),
        stat(  # PostgresDatabaseLarge
            "Largest app database", f'max(pg_database_size_bytes{{{PG}, {APPDB}}})',
            unit="bytes", decimals=1, w=3, thresholds=_line_at(5 * GB),
            desc="Size of the biggest application database (the postgres and template databases "
                 "are left out, as the rule does). Red from 5e9 bytes is rule PostgresDatabaseLarge "
                 "(1 hour): a planning signal, not an outage, half the size at which a high-volume "
                 "app's tables are worth partitioning."),
        stat(  # PostgresDatabaseGrowingFast
            "Fastest growth, 24 h", f'max({GROW_1D})', unit="bytes", decimals=1, w=3,
            thresholds=_line_at(1 * GB),
            desc="The most any application database grew in the last 24 hours (size now minus "
                 "size a day ago). Red from 1e9 bytes is rule PostgresDatabaseGrowingFast "
                 "(30 minutes): at that rate CT 130's free disk lasts weeks, and it fires long "
                 "before PostgresDiskFilling. The rule uses delta(); this subtracts the "
                 "value at offset 1d, the same quantity without the double series the new "
                 "port label caused."),
        stat(  # PostgresOffsiteArchiveStale
            "Off-site WAL archive age",
            f'max(time() - pg_offsite_archive_last_success_timestamp_seconds{{{OFFSITE}}})',
            unit="s", decimals=0, w=3, thresholds=_line_at(3600),
            desc="Time since the last WAL segment reached the B2 bucket (ADR 0034). Normal: at "
                 "most 15 minutes (archive_timeout). Red from 1 hour is rule "
                 "PostgresOffsiteArchiveStale (5 minutes): commits since then exist only at "
                 "home. The series is a textfile written in CT 130; if it vanishes the alert "
                 "is silent, so this tile shows n/a, not green."),
        stat(  # PostgresOffsiteFullBackupOld
            "Newest off-site full backup",
            f'max(time() - pg_offsite_full_backup_last_timestamp_seconds{{{OFFSITE}}})',
            unit="s", decimals=1, w=3, thresholds=_line_at(4 * 86400),
            desc="Age of the newest full backup in the bucket (one is taken every third day at "
                 "04:00 WIB). Red from 4 days is rule PostgresOffsiteFullBackupOld (30 "
                 "minutes): the restore window shrinks; WAL alone still restores, from the older "
                 "full."),
        stat(  # PostgresOffsiteRepoLarge
            "Off-site repo size", f'max(pg_offsite_repo_bytes{{{OFFSITE}}})', unit="decbytes",
            decimals=2, w=3, thresholds=_line_at(8 * GB),
            desc="Size of the pgBackRest repo in B2 against the 10 GB free tier (steady state "
                 "about 4-5 GB). Red from 8e9 bytes is rule PostgresOffsiteRepoLarge (15 "
                 "minutes); at 9 GB the daily job expires down to one full backup (the guard), "
                 "at 10 GB B2's $0 cap refuses writes and the archive stops."),
    ])

    # ---- saturation ----------------------------------------------------------------
    b.row("Is it saturated? Connections, locks, long transactions", [
        timeseries(
            "Connections by state, against max_connections",
            [(f'sum by (state) (pg_stat_activity_count{{{PG}}}) > 0', "{{state}}"),
             (f'max(pg_settings_max_connections{{{PG}}})', "max_connections"),
             (f'0.8 * max(pg_settings_max_connections{{{PG}}})', "alert level (80 %)")],
            desc="Backends by state (a stack: the states sum to the connections in use) against "
                 "max_connections and the 80 % line that rule PostgresConnectionsHigh fires "
                 "above (held 10 minutes). Many 'idle' is a pool holding connections open: "
                 "normal until it nears the limit. 'idle in transaction' that stays above 0 is "
                 "an app that opened a transaction and forgot it (it also blocks vacuum). Series "
                 "at zero are hidden.",
            unit="short", w=12, h=8, stack=True, fill=40, legend="table", legend_calcs=("lastNotNull", "max"),
            overrides=[
                {"matcher": {"id": "byName", "options": "max_connections"}, "properties": [
                    {"id": "custom.stacking", "value": {"mode": "none", "group": "A"}},
                    {"id": "custom.fillOpacity", "value": 0},
                    {"id": "custom.lineWidth", "value": 2},
                    {"id": "color", "value": {"mode": "fixed", "fixedColor": "red"}}]},
                {"matcher": {"id": "byName", "options": "alert level (80 %)"}, "properties": [
                    {"id": "custom.stacking", "value": {"mode": "none", "group": "A"}},
                    {"id": "custom.fillOpacity", "value": 0},
                    {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}},
                    {"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}]},
            ]),
        timeseries(
            "Longest open transaction, by state",
            [(f'max by (state) (pg_stat_activity_max_tx_duration{{{PG}, state=~"active|idle in transaction.*"}})',
              "{{state}}")],
            desc="Age of the oldest open transaction in each state, from the exporter's "
                 "pg_stat_activity query. 'active' is a running query: seconds is normal for a "
                 "report, minutes means a stuck or runaway query. 'idle in transaction' should "
                 "stay near 0: a long one holds locks, blocks vacuum and bloats tables. No alert "
                 "rule; the cure is the app's code (runbook PostgresConnectionsHigh has the "
                 "pg_stat_activity query).",
            unit="s", w=6, h=8),
        timeseries(
            "Locks held, by mode",
            [(f'sum by (mode) (pg_locks_count{{{PG}}}) > 0', "{{mode}}")],
            desc="Locks currently held, by mode, over all databases. A few access-share and "
                 "row-exclusive locks are the normal background of live queries. A climbing "
                 "access-exclusive or share lock count means DDL or a migration is running. "
                 "The exporter counts locks held, not waiters, so a blocked query does not show "
                 "here: look at the longest open transaction. No alert rule.",
            unit="short", w=6, h=8),
    ])

    # ---- health (RED) --------------------------------------------------------------
    b.row("Is it healthy? Transactions, cache, errors", [
        timeseries(
            "Transactions per second, by database",
            [(f'sum by (datname) (rate(pg_stat_database_xact_commit{{{PG}, {ALLDB}}}[$__rate_interval]))',
              "{{datname}} commit"),
             (f'sum by (datname) (rate(pg_stat_database_xact_rollback{{{PG}, {ALLDB}}}[$__rate_interval]))',
              "{{datname}} rollback")],
            desc="Committed and rolled-back transactions per second: the rate of the database's "
                 "work (RED rate and errors). Rollbacks should be a small fraction of commits; a "
                 "line that rises with a failing app is its errors. Flat zero for a database "
                 "that should be busy means the app cannot reach it. No alert rule.",
            unit="ops", decimals=2, w=8, h=8),
        timeseries(
            "Cache hit ratio, by database",
            [(f'sum by (datname) (rate(pg_stat_database_blks_hit{{{PG}, {ALLDB}}}[$__rate_interval]))'
              f' / (sum by (datname) (rate(pg_stat_database_blks_hit{{{PG}, {ALLDB}}}[$__rate_interval]))'
              f' + sum by (datname) (rate(pg_stat_database_blks_read{{{PG}, {ALLDB}}}[$__rate_interval])))',
              "{{datname}}")],
            desc="Share of block reads served from shared_buffers instead of the OS or disk. An OLTP "
                 "workload sits at 95-99 % or more; a falling line means the working set "
                 "outgrew shared_buffers and queries read from disk. A gap is a window with no "
                 "reads at all. No alert rule.",
            unit="percentunit", max=1, decimals=1, w=8, h=8),
        timeseries(
            "Deadlocks in the last hour, by database",
            [(f'sum by (datname) (increase(pg_stat_database_deadlocks{{{PG}, {ALLDB}}}[1h]))', "{{datname}}")],
            desc="Deadlocks Postgres resolved by killing one transaction, over a trailing hour. "
                 "Should be 0: each one is an app error and a sign of two code paths locking "
                 "rows in opposite order. No alert rule.",
            unit="short", w=8, h=8),
    ])

    b.row("Write load, temp files and WAL", [
        timeseries(
            "Rows written per second",
            [(f'sum(rate(pg_stat_database_tup_inserted{{{PG}, {ALLDB}}}[$__rate_interval]))', "inserted"),
             (f'sum(rate(pg_stat_database_tup_updated{{{PG}, {ALLDB}}}[$__rate_interval]))', "updated"),
             (f'sum(rate(pg_stat_database_tup_deleted{{{PG}, {ALLDB}}}[$__rate_interval]))', "deleted")],
            desc="Rows inserted, updated and deleted per second, all databases. The write load "
                 "behind the growth and WAL panels: a runaway insert loop shows here first. No alert "
                 "rule.",
            unit="ops", decimals=2, w=8, h=7),
        timeseries(
            "Temp files written",
            [(f'sum by (datname) (rate(pg_stat_database_temp_bytes{{{PG}, {ALLDB}}}[$__rate_interval]))',
              "{{datname}}")],
            desc="Bytes per second queries spilled to temporary files because a sort or hash "
                 "outgrew work_mem. Occasional bursts are fine; a steady stream means a query "
                 "needs an index or more work_mem, and it adds disk writes. No alert rule.",
            unit="Bps", w=8, h=7),
        timeseries(
            "WAL archived, and segments waiting",
            [(f'max(increase(pg_stat_archiver_archived_count{{{PG}}}[1h]))', "segments archived, 1 h"),
             (f'max(increase(pg_stat_archiver_failed_count{{{PG}}}[1h]))', "archive failures, 1 h"),
             (f'max(pg_offsite_archive_ready_segments{{{OFFSITE}}})', "segments waiting in pg_wal")],
            desc="WAL segments (16 MiB each) Postgres archived to the bucket in the last hour, "
                 "archive_command failures, and segments queued in pg_wal. archive_timeout forces "
                 "a switch every 15 minutes, so about 4 an hour is the idle floor, not the WAL "
                 "rate (the exporter has no WAL-byte or checkpoint counters). Failures above 0 "
                 "or a queue that does not return to 0 means B2 is unreachable: rule "
                 "PostgresOffsiteArchiveStale fires after an hour. Past 4 GiB queued, "
                 "pgBackRest drops segments.",
            unit="short", w=8, h=7),
    ], collapsed=True)

    # ---- size and growth -----------------------------------------------------------
    b.row("How big is it, and how fast does it grow?", [
        timeseries(
            "Database size, by database",
            [(SIZE, "{{datname}}")],
            desc="Size of each database. The dashed line is 5e9 bytes, rule PostgresDatabaseLarge "
                 "(1 hour): a planning signal for the application databases. The postgres "
                 "database is shown (about 8 MB) but the rule leaves it and the templates out.",
            unit="bytes", w=12, h=8, thresholds=_line_at(5 * GB), threshold_style="dashed"),
        timeseries(
            "Growth over the trailing 24 h and 7 d, by database",
            [(GROW_1D, "{{datname}} 24 h"), (GROW_7D, "{{datname}} 7 d")],
            desc="How much each application database grew over the 24 hours and the 7 days "
                 "before each point (size then minus size back then). The dashed line is 1e9 "
                 "bytes in 24 hours, rule PostgresDatabaseGrowingFast (30 minutes). Use the 7 "
                 "d line for the trend: steady slope is fine, a sudden step is a bulk load or "
                 "a runaway. Negative after a vacuum full or a big delete.",
            unit="bytes", min=None, w=12, h=8, legend="table", legend_calcs=("lastNotNull", "max"),
            thresholds=_line_at(1 * GB), threshold_style="dashed"),
    ])

    # ---- disk ----------------------------------------------------------------------
    b.row("Disk of CT 130", [
        timeseries(
            "Root disk used, over time",
            [(ROOT_DISK, "root disk")],
            desc="CT 130's root disk used, from the Proxmox API (data, WAL, the last 3 dumps). "
                 "The dashed line is 80 %, rule PostgresDiskFilling (30 minutes). Fix: grow disk_gb "
                 "in proxmox/opentofu/postgres.tf (online). The CT's CPU and memory are on the "
                 "Host and guest board (pick 'postgres').",
            unit="percentunit", max=1, w=12, h=7, legend="hidden",
            thresholds=_line_at(0.80), threshold_style="dashed"),
        timeseries(
            "Disk runway, days until full",
            [(RUNWAY, "root disk")],
            desc="Days until the root disk is full if the last 7 days of change continue (linear, "
                 "capped at 365; a disk that is not growing reads 365). The dashed lines mark 7 "
                 "days (orange) and 30 days (green): under 30 is worth a plan. Warns "
                 "weeks before rule PostgresDiskFilling, which fires only at 80 % full.",
            unit="d", max=365, w=12, h=7, legend="hidden",
            thresholds=lo_bad(30, 7), threshold_style="dashed"),
    ])

    # ---- off-site copy -------------------------------------------------------------
    b.row("Off-site copy to Backblaze B2: is it current?", [
        stat(  # PostgresOffsiteDailyFailing
            "Daily job, last success",
            f'max(time() - pg_offsite_daily_last_success_timestamp_seconds{{{OFFSITE}}})',
            unit="s", decimals=1, w=4, h=5, thresholds=_line_at(30 * 3600),
            desc="Time since pg-offsite-daily last completed (a full backup when due, the repo "
                 "size, the guard). Red from 30 hours is rule PostgresOffsiteDailyFailing (30 "
                 "minutes). When it stops, the repo size and full-backup series on this board go "
                 "stale. Runbook: PostgresOffsiteDailyFailing."),
        problem_stat(  # PostgresOffsiteGuardExpired
            "Guard expired, last 24 h",
            f'count(pg_offsite_guard_last_expire_timestamp_seconds{{{OFFSITE}}} > 0'
            f' and time() - pg_offsite_guard_last_expire_timestamp_seconds{{{OFFSITE}}} < 86400) or vector(0)',
            warn_only=True, w=4, h=5, empty_ok=False,
            desc="1 when the repo passed 9 GB and the daily job expired it down to one full "
                 "backup within the last 24 hours (rule PostgresOffsiteGuardExpired, fires for a "
                 "day). The restore window is then 0-3 days instead of 3-6 until the repo "
                 "shrinks. 0 is the normal state."),
        stat(
            "Full backups in the repo", f'max(pg_offsite_full_backups{{{OFFSITE}}})',
            unit="short", decimals=0, w=4, h=5, thresholds=steps(("orange", None), ("green", 2)),
            desc="Full backups pgBackRest keeps in the bucket. Two or more is the steady state "
                 "(restore window 3-6 days); one means a newly created repo or a guard expiry "
                 "(window 0-3 days). Orange until the second full is taken. No alert rule beyond "
                 "PostgresOffsiteGuardExpired."),
        timeseries(
            "Newest archived WAL segment, age",
            [(f'max(time() - pg_offsite_archive_last_success_timestamp_seconds{{{OFFSITE}}})', "WAL archive age")],
            desc="Time since the last WAL segment reached the bucket, as a saw-tooth: it climbs "
                 "to at most 15 minutes (archive_timeout) and drops on each upload. The dashed "
                 "line is 1 hour, rule PostgresOffsiteArchiveStale (5 minutes). A line that "
                 "keeps climbing past it is B2 unreachable, a revoked key or a full bucket.",
            unit="s", w=12, h=5, legend="hidden",
            thresholds=_line_at(3600), threshold_style="dashed"),
    ])
    b.row("Off-site copy: full backups and repo size", [
        timeseries(
            "Newest full backup and daily job, age",
            [(f'max(time() - pg_offsite_full_backup_last_timestamp_seconds{{{OFFSITE}}})', "newest full backup"),
             (f'max(time() - pg_offsite_daily_last_success_timestamp_seconds{{{OFFSITE}}})', "daily job, last success")],
            desc="Age of the newest full backup (a full is taken every third day at 04:00 WIB) "
                 "and of the daily job's last completed run (every day at 04:00 WIB). The "
                 "dashed line is 4 days, rule PostgresOffsiteFullBackupOld (30 minutes); the "
                 "daily job's own limit is 30 hours, rule PostgresOffsiteDailyFailing (tile "
                 "above). The daily line should saw-tooth under a day, the full under 3 days.",
            unit="s", w=12, h=8, thresholds=_line_at(4 * 86400), threshold_style="dashed"),
        timeseries(
            "Off-site repo size against the 10 GB free tier",
            [(f'max(pg_offsite_repo_bytes{{{OFFSITE}}})', "repo size")],
            desc="Size of the pgBackRest repo in B2. The dashed lines are 8e9 bytes (orange), "
                 "rule PostgresOffsiteRepoLarge (15 minutes), and 9e9 (red), where the daily "
                 "job expires down to one full backup. B2's free tier is 10 GB, and its $0 "
                 "cap refuses writes at the limit. Steady state is about 4-5 GB; it was 110 MB "
                 "right after archiving went live (2026-11-09), so expect a climb. B2's "
                 "own bucket size, including hidden versions, is only in its web UI.",
            unit="decbytes", w=12, h=8, legend="hidden",
            thresholds=steps(("green", None), ("orange", 8 * GB), ("red", 9 * GB)),
            threshold_style="dashed"),
    ], collapsed=True)

    # ---- the server's own log ------------------------------------------------------
    b.row("Server log", [
        logs(
            "PostgreSQL: errors, fatals and panics",
            '_stream:{_HOSTNAME="postgres"} (level:(error or critical) or ERROR or FATAL or PANIC)',
            desc="Error-level lines from CT 130's journal (syslog identifier postgres): ERROR "
                 "statements, FATAL connection failures and PANICs, plus anything the journal "
                 "marks error or critical. A few ERROR lines from application SQL (duplicate "
                 "keys) are normal; FATAL or PANIC, or a burst, is the story behind an alert. "
                 "Not checked by --verify-live.",
            w=24, h=10),
    ])
    return [b]
