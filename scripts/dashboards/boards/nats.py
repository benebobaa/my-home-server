"""NATS (JetStream): "is the shared NATS hub up, is JetStream healthy, and is every
consumer keeping up?" The one nats-server in CT 131 (job service, instance nats:
prometheus-nats-exporter on :7777 for the gnatsd_* and jetstream_* series, the server's
own health URL on :8222 through the blackbox job). Kubeletto's cluster joins it as a leaf
node; there is one JetStream account (kubeletto), so the "per account" series are one
account today.

Top row = the answer (8 stats). Mirrored rules, in services/monitoring/prometheus/rules/
app-nats.yml: NatsAccountStorageHigh, NatsConsumerBacklog, NatsDiskFilling. Down, or up
without JetStream, is HttpProbeFailed on healthz?js-enabled-only=true (rules/network.yml)
and TargetDown for the exporter (rules/meta.yml): the first tile is that probe times the
scrape. Below, one row per question: traffic, streams and consumers, disk and the server
process, the leaf link, the server log.

Sources: the queries are derived from the live metric names on the lab's Prometheus, from
the alert rules above, and from the previous app-nats board's queries (git history,
0b2d5b6:services/monitoring/grafana/dashboards/app-nats.json), each re-checked against
live data. No upstream mixin or vendor dashboard was consulted.

Facts that shaped the queries (checked against the live data):
- gnatsd_varz_connections is 0 and stays 0: Kubeletto's pods reach the hub through ONE leaf
  node connection (gnatsd_varz_leafnodes = 1, gnatsd_accstatz_leaf_nodes{account="kubeletto"}
  = 1), so "clients connected" is the wrong health signal; the leaf count is the one.
- The jetstream_* series carry leader, server_id and domain labels; panels aggregate
  with `sum by` / `max by` to the labels worth reading.
- jetstream_stream_limit_bytes / _messages are -1 on the unlimited (DLQ) streams: every
  fill ratio divides by `(limit > 0)`.
- jetstream_consumer_last_ack_seconds is already the elapsed seconds since the last ack
  (72291 is about 20 hours), not a timestamp, and it exists only for consumers that have
  acked at least once (5 of 10 today).
- gnatsd_healthz_status / _value are not used: the blackbox probe of the same health URL
  is what the alert reads.
- Not exported (a data gap): leaf-node link detail (the exporter's leafz collector is off,
  so there is no per-leaf RTT, in/out or last-seen), per-stream publish counters (the
  publish rate is derived from the stream's last sequence number), and the CT's own CPU
  and memory (the CT's node_exporter does not exist; the Host and guest board has the
  Proxmox view).
"""
from lib import (
    board, stat, up_stat, problem_stat, timeseries, table, logs,
    steps,
)

N = 'job="service", instance="nats"'
# CT 131's root disk, exactly as NatsDiskFilling reads it (JetStream's file store lives there).
ROOT_DISK = ('(pve_disk_usage_bytes / pve_disk_size_bytes)'
             ' * on (id) group_left (name) pve_guest_info{name="nats"}')

STORAGE_SHARE = (f'jetstream_account_storage_used{{{N}}}'
                 f' / jetstream_account_max_storage{{{N}}}')


def _line_at(value: float) -> dict:
    """A dashed boundary line is drawn in the colour of the step that starts there."""
    return steps(("green", None), ("red", value))


def _col(name: str, *props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": i, "value": v} for i, v in props]}


def boards():
    b = board(
        uid="homelab-platform-nats", title="NATS (JetStream)", folder="Platform services",
        description="Is the shared NATS hub (CT 131) up, is JetStream healthy and is every "
                    "consumer keeping up? Open it after a Nats* alert or an HttpProbeFailed on "
                    "the nats health URL, when Kubeletto's events stall, and weekly for storage.",
        method="red", filename="nats",
    )

    # ---- the answer ----------------------------------------------------------------
    b.row("Is the hub up and JetStream healthy?", [
        up_stat(  # HttpProbeFailed (nats health URL), TargetDown
            "Hub up",
            f'(min(up{{{N}}}) * min(probe_success{{job="blackbox_http", instance="nats"}})) or vector(0)',
            w=3,
            desc="The server answers its health URL with JetStream enabled "
                 "(healthz?js-enabled-only=true; rule HttpProbeFailed, 5 minutes, critical for "
                 "this critical-tier host) and the exporter scrape works (rule TargetDown). DOWN "
                 "means Kubeletto's event flow (builds, deployments, notifications) is stalled. "
                 "Next: 'systemctl status nats' in CT 131 and the Server log row."),
        up_stat(
            "JetStream enabled", f'(1 - max(jetstream_server_jetstream_disabled{{{N}}})) or vector(0)',
            w=3,
            desc="The exporter's own view of the server: JetStream on or off. The health probe in "
                 "the tile beside it already fails (rule HttpProbeFailed) when the server is up "
                 "without JetStream; this tile says which half is wrong. No separate alert."),
        stat(  # NatsAccountStorageHigh
            "Account storage, fullest", f'max({STORAGE_SHARE})', unit="percentunit",
            decimals=2, w=3, thresholds=_line_at(0.80),
            desc="Real bytes stored by the fullest JetStream account over its limit (8 GiB for "
                 "kubeletto), not the streams' reservations. Red from 80 % is rule "
                 "NatsAccountStorageHigh (30 minutes); at 100 % publishes to its streams are "
                 "refused. Tiny today: streams are capped by messages and age."),
        stat(  # NatsConsumerBacklog
            "Largest consumer backlog", f'max(jetstream_consumer_num_pending{{{N}}})',
            unit="short", w=3, thresholds=_line_at(1000),
            desc="Messages waiting for the most-behind durable consumer. Red above 1000 is rule "
                 "NatsConsumerBacklog (15 minutes): that consumer's app stopped consuming (down, "
                 "stuck, or a poison message). The Consumers table names it."),
        problem_stat(
            "Messages being redelivered", f'sum(jetstream_consumer_num_redelivered{{{N}}})',
            warn_only=True, w=3,
            desc="Messages JetStream has had to deliver again because a consumer did not ack in "
                 "time, summed over every consumer (a gauge of messages currently redelivering). "
                 "0 is healthy; a number that stays above 0 is a poison message or a slow "
                 "handler. No alert mirrors it."),
        stat(  # NatsDiskFilling
            "Root disk used", f'max({ROOT_DISK})', unit="percentunit", decimals=0, w=3,
            thresholds=_line_at(0.80),
            desc="CT 131's root disk, which holds the JetStream file store, from the Proxmox API. "
                 "Red from 80 % is rule NatsDiskFilling (30 minutes). The CT has no "
                 "node_exporter, so this is the only disk series. The Disk row has the history."),
        stat(
            "Leaf links up", f'sum(gnatsd_varz_leafnodes{{{N}}})', unit="short", w=3,
            thresholds=steps(("red", None), ("green", 1)),
            desc="Leaf-node connections to the hub. Kubeletto's cluster joins as one leaf, so "
                 "1 is healthy and 0 means the cluster is cut off from the hub (every client "
                 "count reads 0 anyway: apps never connect directly). No alert mirrors it: a "
                 "dead leaf shows first as a growing consumer backlog."),
        problem_stat(
            "Slow consumers, 1 h", f'sum(increase(gnatsd_varz_slow_consumers{{{N}}}[1h]))',
            warn_only=True, w=3,
            desc="Connections the server cut off for not reading fast enough, in the last hour "
                 "(its slow-consumer counter). Should be 0: a slow reader loses messages "
                 "that are not in JetStream. No alert mirrors it."),
    ])

    # ---- traffic (RED) -------------------------------------------------------------
    b.row("Traffic: rate and errors", [
        timeseries(
            "Messages per second, in and out",
            [(f'rate(gnatsd_varz_in_msgs{{{N}}}[$__rate_interval])', "in"),
             (f'rate(gnatsd_varz_out_msgs{{{N}}}[$__rate_interval])', "out")],
            desc="Messages the server received and delivered per second, over every connection "
                 "(here: the one leaf link). Out runs above in because a message can be delivered "
                 "to several subscribers and JetStream consumers. A flat zero while Kubeletto "
                 "runs means the leaf or the apps are silent. No alert rule.",
            unit="ops", decimals=2, w=8, h=7),
        timeseries(
            "Bytes per second, in and out",
            [(f'rate(gnatsd_varz_in_bytes{{{N}}}[$__rate_interval])', "in"),
             (f'rate(gnatsd_varz_out_bytes{{{N}}}[$__rate_interval])', "out")],
            desc="Payload bytes received and delivered per second. Events are small (tens of "
                 "bytes per second at rest). A step up means a bulk publisher; compare with "
                 "the stream sizes below. No alert rule.",
            unit="Bps", w=8, h=7),
        timeseries(
            "JetStream API requests and errors per second",
            [(f'rate(gnatsd_varz_jetstream_stats_api_total{{{N}}}[$__rate_interval])', "API requests"),
             (f'rate(gnatsd_varz_jetstream_stats_api_errors{{{N}}}[$__rate_interval])', "API errors")],
            desc="Requests to JetStream's management API (stream and consumer info, ack and "
                 "pull handling) and the ones that failed. Errors should be 0; a line above 0 "
                 "is a client asking for a stream or consumer that does not exist or that "
                 "refuses the request. No alert rule.",
            unit="reqps", decimals=2, w=8, h=7),
    ])

    # ---- streams and consumers -----------------------------------------------------
    b.row("Is every consumer keeping up, and is storage safe?", [
        timeseries(
            "Account storage used, share of its limit",
            [(f'max by (account) ({STORAGE_SHARE})', "{{account}}")],
            desc="Real bytes stored by each JetStream account over its limit (max_file in "
                 "proxmox/opentofu/nats.tf). The dashed line is 80 %, rule NatsAccountStorageHigh "
                 "(30 minutes). Usually the cause is a stream with no max_age or max_bytes, or "
                 "a consumer that never acks. Near zero today.",
            unit="percentunit", max=1, decimals=2, w=8, h=8, legend="hidden",
            thresholds=_line_at(0.80), threshold_style="dashed"),
        timeseries(
            "Consumer backlog, by consumer",
            [(f'max by (stream_name, consumer_name) (jetstream_consumer_num_pending{{{N}}})',
              "{{stream_name}} / {{consumer_name}}")],
            desc="Messages waiting for each durable consumer. The dashed line is 1000, rule "
                 "NatsConsumerBacklog (15 minutes). A line that climbs and does not come back "
                 "is an app that stopped consuming; a brief spike after a deploy is normal. The "
                 "labels name the stream and consumer (all of them are Kubeletto's today).",
            unit="short", w=8, h=8, legend="table", legend_calcs=("lastNotNull", "max"),
            thresholds=_line_at(1000), threshold_style="dashed"),
        timeseries(
            "Redelivered and unacked messages",
            [(f'sum(jetstream_consumer_num_redelivered{{{N}}})', "redelivered"),
             (f'sum(jetstream_consumer_num_ack_pending{{{N}}})', "awaiting ack")],
            desc="Over every consumer: messages being redelivered (a handler timed out or "
                 "crashed) and messages delivered but not yet acked. A short burst of "
                 "awaiting-ack is a handler working. Redelivered that stays above 0 is a "
                 "poison message (it ends in the DLQ_* stream if the app has one). The "
                 "Consumers table below names the consumer. No alert rule.",
            unit="short", w=8, h=8),
    ])

    b.row("Streams: what they hold", [
        timeseries(
            "Stream size, by stream",
            [(f'sum by (stream_name) (jetstream_stream_total_bytes{{{N}}}) > 0', "{{stream_name}}")],
            desc="Bytes held by each stream. Each is capped by its own limit (500 MiB) and by "
                 "age, so a line that climbs steadily toward the cap is a stream that is "
                 "not being consumed or trimmed. Streams at zero are hidden. Their sum is the "
                 "account storage above. No alert rule.",
            unit="bytes", w=8, h=8, legend="table", legend_calcs=("lastNotNull",)),
        timeseries(
            "Messages published per second, six busiest streams",
            [(f'topk(6, sum by (stream_name) (rate(jetstream_stream_last_seq{{{N}}}[$__rate_interval])))',
              "{{stream_name}}")],
            desc="Messages appended per second to the six busiest streams, derived from each "
                 "stream's last sequence number (the exporter has no publish counter). When "
                 "the hub is quiet all six read 0 and which six are drawn is arbitrary. A "
                 "stream that should be busy and is flat is a publisher that stopped. No "
                 "alert rule.",
            unit="ops", decimals=3, w=8, h=8),
        table(
            "Streams",
            [(f'max by (stream_name) (jetstream_stream_total_messages{{{N}}})', ""),
             (f'max by (stream_name) (jetstream_stream_total_bytes{{{N}}})', ""),
             (f'max by (stream_name) (jetstream_stream_limit_messages{{{N}}} > 0)', ""),
             (f'max by (stream_name) (jetstream_stream_limit_bytes{{{N}}} > 0)', ""),
             (f'max by (stream_name) (jetstream_stream_consumer_count{{{N}}})', "")],
            desc="Every stream: messages and bytes held, its own limits (blank = unlimited: the "
                 "DLQ_* dead-letter streams) and how many consumers read it. A stream near "
                 "its message or byte limit discards old messages or refuses new ones, per its "
                 "discard policy. A stream with 0 durable consumers is only written to; several "
                 "are today. No alert rule.",
            columns=[("stream_name", "Stream"), ("Value #A", "Messages"), ("Value #B", "Size"),
                     ("Value #C", "Message limit"), ("Value #D", "Size limit"),
                     ("Value #E", "Consumers")],
            overrides=[
                _col("Size", ("unit", "bytes")), _col("Size limit", ("unit", "bytes")),
            ],
            sort_by="Size", w=24, h=9),
    ], collapsed=True)

    # ---- disk and the server process (USE) -----------------------------------------
    b.row("Disk and the server process (USE)", [
        timeseries(
            "Root disk used, over time",
            [(ROOT_DISK, "root disk")],
            desc="CT 131's root disk, which holds the JetStream file store, from the Proxmox API. "
                 "The dashed line is 80 %, rule NatsDiskFilling (30 minutes). Fix: find the "
                 "stream that grew (du in /var/lib/nats/jetstream), or grow disk_gb in "
                 "proxmox/opentofu/nats.tf (online).",
            unit="percentunit", max=1, w=6, h=7, legend="hidden",
            thresholds=_line_at(0.80), threshold_style="dashed"),
        timeseries(
            "JetStream reservations, share of the server maximum",
            [(f'max(gnatsd_varz_jetstream_stats_reserved_storage{{{N}}})'
              f' / max(gnatsd_varz_jetstream_config_max_storage{{{N}}})', "reserved / max_file")],
            desc="Disk the streams have reserved with a byte cap, over the server's JetStream "
                 "storage limit (10 GiB). Reservations are promises, not bytes in use: past "
                 "100 % the server refuses to create another capped stream. Not the NatsDisk "
                 "rules' number: those read real bytes. No alert rule.",
            unit="percentunit", max=1, w=6, h=7, legend="hidden"),
        timeseries(
            "Server memory",
            [(f'max(gnatsd_varz_mem{{{N}}})', "resident memory")],
            desc="Resident memory of the nats-server process. Tens of MB for this workload; "
                 "growth that does not come back is a leak or a huge number of subscriptions. "
                 "The CT's own memory is on the Host and guest board. No alert rule.",
            unit="bytes", w=6, h=7, legend="hidden"),
        timeseries(
            "Server CPU",
            [(f'max(gnatsd_varz_cpu{{{N}}})', "CPU")],
            desc="CPU the nats-server process uses, in percent of one core, as the server "
                 "reports it. Near zero at rest; sustained tens of percent means message "
                 "volume or a hot consumer. No alert rule.",
            unit="percent", w=6, h=7, legend="hidden"),
    ], collapsed=True)

    # ---- the leaf link -------------------------------------------------------------
    b.row("Leaf connection from the Kubeletto cluster", [
        timeseries(
            "Leaf links and client connections",
            [(f'max(gnatsd_varz_leafnodes{{{N}}})', "leaf links"),
             (f'max(gnatsd_varz_connections{{{N}}})', "direct client connections"),
             (f'max(gnatsd_varz_routes{{{N}}})', "cluster routes")],
            desc="Connections to the hub by kind. Kubeletto's cluster joins through one leaf "
                 "link, so 'leaf links' should hold at 1 and a drop to 0 is the cluster cut "
                 "off (the network path to the hub, or the hub restarting). Direct client "
                 "connections and cluster routes stay at 0 by design: this is a single server "
                 "and apps reach it only through the leaf. No alert rule.",
            unit="short", w=12, h=7),
        timeseries(
            "Slow consumers and stale connections",
            [(f'sum(increase(gnatsd_varz_slow_consumers{{{N}}}[$__rate_interval]))', "slow consumers"),
             (f'sum(increase(gnatsd_varz_slow_consumer_stats_leafs{{{N}}}[$__rate_interval]))',
              "slow consumers, leaf"),
             (f'sum(increase(gnatsd_varz_stale_connections{{{N}}}[$__rate_interval]))', "stale connections")],
            desc="Connections the server dropped because a reader fell behind (slow consumers, "
                 "and the share that were the leaf link) or stopped answering pings (stale), "
                 "counted per window. Should stay at 0. A leaf slow consumer means the "
                 "cluster side cannot keep up with what the hub sends. No alert rule.",
            unit="short", w=12, h=7),
    ])

    # ---- the server's own log ------------------------------------------------------
    b.row("Server log", [
        logs(
            "NATS: errors and warnings",
            '_stream:{_HOSTNAME="nats"} ("[ERR]" or "[WRN]" or level:(error or critical))',
            desc="Server lines tagged [ERR] or [WRN] by nats-server, plus anything the journal "
                 "marks error or critical. A few warnings at start-up (JetStream recovery, a "
                 "leaf reconnect) are normal; a stream of them is the story behind an alert. "
                 "Not checked by --verify-live.",
            w=24, h=10),
    ])
    return [b]
