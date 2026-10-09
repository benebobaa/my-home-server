# Remote syslog → the lab log store (VictoriaLogs, CT 121 `logs`;
# services/logs). Design §9 asked for hEX remote logging; ADR 0008 is where
# it lands. BSD syslog over UDP (RouterOS sends the syslog format over UDP
# only; TCP/TLS are for CEF), ISO 8601 timestamps so no timezone guessing.
# UDP can drop a line under load; the local memory log keeps a copy.
#
# The default memory/echo rules stay: the local log still works when the
# store is down. Output from the router itself is not filtered (no output
# chain rules), so no firewall rule is needed.
resource "routeros_system_logging_action" "lab_logs" {
  name               = "lablogs"
  target             = "remote"
  remote             = local.host.logs.ip
  remote_port        = 5514
  remote_protocol    = "udp"
  remote_log_format  = "syslog"
  syslog_time_format = "iso8601"
  src_address        = local.host.hex.ip
}

# One rule per topic: the topics in one rule are combined (that is how
# `wireless,!debug` excludes debug), so one rule listing all four would match
# almost nothing.
resource "routeros_system_logging" "lab_logs" {
  for_each = toset(["info", "warning", "error", "critical"])

  action = routeros_system_logging_action.lab_logs.name
  topics = [each.key]
}
