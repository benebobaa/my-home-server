# monitoring — Prometheus, Alertmanager, Grafana

Metrics, alerts and dashboards for the whole lab, in CT 120 on pve2
(`10.10.10.16`, VLAN 10). Alerts go to one Telegram chat. A dead-man's switch
at healthchecks.io covers the case where the whole house goes dark. Why this
stack and why VLAN 10: [ADR 0006](../../docs/decisions/0006-monitoring-stack.md).

| | |
| --- | --- |
| Grafana | `http://10.10.10.16:3000` (or `monitoring.home.arpa`), user `admin`. Password: `sops decrypt --extract '["TF_VAR_monitoring_grafana_admin_password"]' proxmox/opentofu/secrets.sops.env` |
| Prometheus | `http://10.10.10.16:9090` (targets, alerts, ad-hoc queries; no login, MGMT only) |
| Alertmanager | `http://10.10.10.16:9093` (active alerts, silences) |
| Retention | 30 days, capped at 8 GB (12 GB disk) |
| Built by | `proxmox/opentofu/monitoring.tf` → `setup.sh`, `secrets.sh` (in guest), `files/monitoring-pve-token.sh`, `files/monitoring-pve-notify.sh` (pve2, root) |
| Host side | Ansible `--tags monitoring` (node_exporter + SMART/thin-pool collectors on pve2/pve3) |
| Router side | `network/routeros/snmp.tf` (SNMPv3 user `monitoring`) + firewall `monitoring` rules |

All of it is reachable from the operator Mac over Tailscale (admin-gw routes
10.10.10.0/24). Prometheus and Alertmanager have no login: they are reachable
only from TRUSTED, MGMT and admin-gw, the same as the Proxmox UIs.

## What is watched

| Job | Targets | How |
| --- | --- | --- |
| `node` | pve2, pve3 (`:9100` on the MGMT IP), the CT itself | node_exporter + textfile collectors: SMART every 15 min (`smartctl -i -H -A`, never a self-test), LVM thin pool every minute, apt |
| `pve` | cluster `homelab` via pve2 (guests, storage, quorum); pve3's node config | prometheus-pve-exporter 3.10.1 (venv), token `prometheus@pve!monitoring` (PVEAuditor) |
| `snmp_hex` | hEX `10.10.10.1` | snmp_exporter, SNMPv3 authPriv (SHA/AES), modules `system if_mib hrDevice hrStorage mikrotik`. A walk takes ~2.5 s every 60 s, about 1 % CPU on the hEX |
| `blackbox_icmp` | hex, switch, pve2, pve3, admin-gw, archive, 1.1.1.1, 8.8.8.8 | ping |
| `blackbox_http` | switch UI, both PVE UIs | any HTTP answer |
| `blackbox_dns` | hEX resolver | resolves `cloudflare.com` |

## Alerts

Rules live in `prometheus/rules/`, one file per area. Every rule set is
validated with `promtool` before a reload. Highlights:

| Alert | Why it exists |
| --- | --- |
| `Watchdog` → healthchecks.io | Always firing. If the pings stop (power cut, pve2 down, internet down, the stack dead), healthchecks.io alerts on its own |
| `HostOnBattery` | Both nodes are laptops: losing AC is the earliest sign of a power cut |
| `DiskPendingSectors`, `DiskSmartFailing`, `DiskReallocatedSectorsGrowing` | pve3's HDD died with 8,448 pending sectors. pve2's HDD already has 9 reallocated sectors (2026-10-09), so the alert is on *growth* |
| `ThinPoolFilling` (>85 %) / `ThinPoolCritical` (>92 %) | Guests freeze at 100 %. The pool auto-extends at 80 % into a small buffer |
| `PveClusterNotQuorate`, `PveNodeDown`, `PveGuestDown` | Two-node quorum. `PveGuestDown` covers onboot guests only (the archive CT is not boot-safe yet) |
| `HostUnreachable`, `InternetDown`, `DnsResolverFailing`, `RouterWanLinkDown` | Reachability. Telegram cannot be reached while the internet is down: those alerts arrive afterwards, as a record of the outage |
| `TargetDown`, `HostTextfileCollectorStale`, `AlertmanagerNotificationsFailing` | The monitoring itself going blind |

Inhibitions (`alertmanager/alertmanager.yml`): an unreachable host suppresses
its own scrape and probe alerts, and a node that is down suppresses its
guests' alerts.

Not yet: backups (`pve_not_backed_up_total`, with PBS), the public tunnel
(an external HTTP check, with Cloudflare Tunnel), hEX remote syslog / logs,
UPS (NUT), GPU metrics.

## Operator steps (account-level, once)

Until these are done, alerts are evaluated but routed to `blackhole`
(visible at `:9093`, nothing is sent).

1. **Telegram bot:** in Telegram, message **@BotFather** → `/newbot` →
   name it (e.g. `benelabs alerts`) → username ending in `bot` → copy the
   **token**. Send your new bot any message, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy
   `"chat":{"id":…}`.
2. **healthchecks.io:** sign up (free) → **Add Check** `homelab-watchdog`,
   **Period 5 minutes, Grace 5 minutes** → copy the **ping URL**. Under
   **Integrations**, add **Telegram** (it walks you through its own bot) and
   enable it for this check.
3. `sops edit proxmox/opentofu/secrets.sops.env` and add:
   ```
   TF_VAR_monitoring_telegram_bot_token=…
   TF_VAR_monitoring_telegram_chat_id=…
   TF_VAR_monitoring_healthchecks_ping_url=https://hc-ping.com/…
   ```
4. `cd proxmox/opentofu && sops exec-env secrets.sops.env 'tofu apply'`.
   This re-renders Alertmanager and points Proxmox's own notifications
   (backup jobs, fencing, updates) at the same chat.
5. Verify: healthchecks.io shows the check **up** within a minute.
   `pvesh create /cluster/notifications/targets/telegram/test` on a node
   sends a Proxmox test message. A test alert:
   `ssh root@10.10.10.12 'pct exec 120 -- amtool --alertmanager.url=http://127.0.0.1:9093 alert add Test severity=warning instance=manual'`.

## Changing things

- **Any file in this directory** → `tofu apply` in `proxmox/opentofu`. It
  streams the directory into the CT, runs `setup.sh`, then `secrets.sh`
  (`terraform_data.monitoring_setup`, keyed on the files' hashes). Never edit
  configs in the CT: the next apply overwrites them.
- **A new scrape target** in another VLAN needs the hEX to allow it: ICMP is
  already open to `10.10.0.0/16` + the switch (`forward_monitoring_icmp`).
  Anything else (an exporter port) needs a new exact rule in
  `network/routeros/firewall.tf`.
- **Silence** during planned work: Alertmanager UI → New Silence, or
  `amtool silence add instance=pve3 --duration 1h --comment reboot`.
- **Dashboards** are pinned grafana.com revisions + sha256 (`setup.sh`,
  `DASHBOARDS`). UI edits are not saved: bump the pin, or add a JSON file to
  the repo.
- **Versions**: Prometheus, Alertmanager and the exporters are Debian 13
  packages (security updates via apt). Grafana is pinned and held
  (`GRAFANA_VERSION`). pve-exporter is pinned (`PVE_EXPORTER_VERSION`). The
  SNMP module file is pinned to the packaged exporter's release
  (`SNMP_YML_VERSION`).

## Gotchas found while building

- Debian's `snmp.yml` is a stub (MIB licensing). The upstream generated
  file goes to `/etc/prometheus/snmp-modules.yml`, beside Debian's conffile.
- ICMP probes: the blackbox package sets a file capability on the binary,
  which clears ambient capabilities and grants nothing in an unprivileged CT.
  Use unprivileged ping sockets instead (`net.ipv4.ping_group_range` = the
  `prometheus` gid, `/etc/sysctl.d/60-blackbox-ping.conf`).
- pve-exporter (gunicorn) needs a writable temp dir under `ProtectSystem=strict`
  (`PrivateTmp=true`).
- `amtool check-config` rejects `chat_id: 0`. The unconfigured placeholder is
  `1` on a receiver that is not routed to.
- Tofu prints `(output suppressed due to sensitive value in config)` for these
  steps, because the SSH key path variable is marked sensitive. To debug, run
  the same command by hand: `ssh root@10.10.10.12 'pct exec 120 -- bash /root/monitoring/setup.sh'`.
