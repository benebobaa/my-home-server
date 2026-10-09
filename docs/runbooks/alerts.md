# Alerts — what each one means and what to do

Every Prometheus rule links here (`runbook_url`; the Telegram message has a
**runbook** link). One section per alert, named exactly like the alert.
Rules: `services/monitoring/prometheus/rules/`. Routing and severities:
[ADR 0008](../decisions/0008-observability-standard.md).

Common commands (from the operator Mac over Tailscale):

```bash
# Silence during planned work (Grafana → Alerting → Silences works too)
ssh root@10.10.10.12 'pct exec 120 -- amtool --alertmanager.url=http://127.0.0.1:9093 silence add instance=pve3 --duration 1h --comment reboot'
# What is firing right now
curl -s http://10.10.10.16:9090/api/v1/alerts | python3 -m json.tool | grep -E 'alertname|instance|state'
# A host's logs (VictoriaLogs, once CT 121 exists): Grafana → Explore → VictoriaLogs
#   _stream:{_HOSTNAME="<instance>"}
```

Severity: **critical** pages now. **warning** is held 23:00–07:00 WIB.
**info** arrives silently. Generic alerts (`HostUnreachable`,
`HttpProbeFailed`, `TargetDown`) take their severity from the host's `tier`
in `inventory/lab.yaml`.

---

## Reachability and services

### HostUnreachable
**Meaning:** a host in `lab.yaml` has not answered ping for 3 min.
**Check:** the Service dashboard for that host. Guest → `pct status <vmid>` on
its node. Node → is it powered and on the switch (`docs/runbooks/node-ops.md`)?
Device → the hEX/switch UI from the operator Mac.
**Fix:** start the guest (`pct start <vmid>`), or bring the node back. Other
alerts for the same host are inhibited while this one fires.

### HttpProbeFailed
**Meaning:** the `health:` URL in `lab.yaml` has not answered as expected
for 5 min (2xx, or any answer for `health_module: http_any`). The host still
pings.
**Check:** `curl -sv <health URL>` from CT 120. In the guest:
`systemctl status <service>` and its journal.
**Fix:** restart the service. If it keeps failing, find the cause in its logs
before restarting again.

### TargetDown
**Meaning:** Prometheus cannot scrape an exporter or `/metrics` endpoint. That
is a blind spot, not necessarily an outage.
**Check:** Prometheus → Status → Targets (`http://10.10.10.16:9090/targets`)
shows the error. A host outside MGMT needs the hEX scrape rule
(`forward_monitoring_scrape`, generated from `metrics:`).
**Fix:** restart the exporter. If it is a new target, `tofu apply` in
`network/routeros`.

### InternetDown
**Meaning:** 1.1.1.1 and 8.8.8.8 both silent for 3 min: the Biznet uplink is
down. Telegram is unreachable while it lasts; this arrives afterwards.
**Check:** `RouterWanLinkDown` (cable/ONT) vs the Biznet router itself.
**Fix:** power-cycle the ONT and Biznet router. Nothing in the lab to do.

### DnsResolverFailing
**Meaning:** the hEX resolver cannot resolve `cloudflare.com`.
**Check:** `InternetDown` first. Else `ssh admin@10.10.10.1 '/ip dns print'`.
**Fix:** `/ip dns cache flush`. If the upstreams changed, converge
`network/routeros`.

## Router (hEX)

### RouterWanLinkDown
**Meaning:** ether1 (uplink to the Biznet router) has no link.
**Fix:** check the cable and the Biznet router. Physical: operator.

### RouterCpuHigh
**Meaning:** hEX CPU above 85 % for 10 min.
**Check:** `ssh admin@10.10.10.1 '/tool profile duration=10'`. Usual causes:
a scan hitting the firewall, a log flood, SNMP walks.
**Fix:** find the source in `/ip firewall connection print count-only` and
the profile. Throttle or block it as code (`network/routeros`).

### RouterMemoryHigh
**Meaning:** hEX memory above 90 % for 15 min (256 MB total).
**Check:** `/system resource print`. Large connection tables or address lists
are the usual cause.
**Fix:** reboot the hEX in a quiet moment if it is a leak (snapshot first,
`./scripts/hex-snapshot.sh`).

### RouterHot
**Meaning:** hEX board above 70 °C for 15 min.
**Fix:** airflow. Physical: operator.

### RouterRebooted
**Meaning:** the hEX came up less than 10 min ago. It has no battery: usually a
power cut. Info only.
**Check:** `HostOnBattery` at the same time confirms a power cut.

## Proxmox cluster

### PveClusterNotQuorate
**Meaning:** the two-node cluster lost quorum. Guests keep running. Starting,
stopping and configuring guests, and backups, are locked.
**Check:** `pvecm status` on the surviving node. Which node is gone?
**Fix:** bring the other node back (`docs/runbooks/proxmox-cluster.md`). Only
in an emergency, on the survivor: `pvecm expected 1`.

### PveNodeDown
**Meaning:** a node is offline in the cluster.
**Fix:** as `HostUnreachable` for that node; then wait for `Quorate: Yes`.

### PveGuestDown
**Meaning:** a guest with `onboot=1` is not running.
**Check:** `pct status <vmid>` / `qm status <vmid>`; the start log with
`pct start <vmid> --debug`.
**Fix:** start it. If it was stopped on purpose, set `start_on_boot = false`
in its Tofu definition instead of leaving the alert.

### PveStorageFilling
**Meaning:** a directory storage (`local`: ISOs, templates, backups) is over
90 % full.
**Fix:** remove old templates/ISOs (`pveam list local`, `pvesm free`).

## Hosts (pve2, pve3, the monitoring CT)

### HostOnBattery
**Meaning:** a laptop node lost AC power: the first sign of a power cut, or
an unplugged adapter.
**Check:** both nodes on battery = house power; one = its adapter.
**Fix:** physical: operator. With a long cut, shut down guests cleanly
before the battery runs out (`docs/runbooks/node-ops.md`).

### HostMemoryLow
**Meaning:** under 10 % memory available for 15 min.
**Check:** `pvesh get /nodes/<node>/lxc` (per-guest memory), `top -o %MEM`.
**Fix:** lower a guest's memory or move a stateless guest to the other node,
as code (`proxmox/opentofu`).

### HostFilesystemFull
**Meaning:** under 15 % free on a filesystem for 15 min.
**Check:** `du -xh --max-depth=2 <mountpoint> | sort -h | tail`.
**Fix:** clear the cause (old kernels: `apt autoremove`; logs:
`journalctl --vacuum-size=200M`).

### ThinPoolFilling
**Meaning:** the guest thin pool (`pve/data`) is over 85 % allocated. It
auto-extends at 80 % into a small VG buffer, so that buffer is being used up.
**Check:** `lvs -a pve`; which guest grew: `pvesh get /nodes/<node>/storage/local-lvm/content`.
**Fix:** `fstrim` in the guests (`pct fstrim <vmid>`), shrink or move a guest,
or add disk. At 100 % every guest on the pool freezes.

### ThinPoolCritical
**Meaning:** thin pool over 92 %. Guests freeze at 100 % and can corrupt.
**Fix:** now: `pct fstrim` every guest on that node, stop the largest
non-essential guest. Then as for `ThinPoolFilling`.

### ThinPoolMetadataFilling
**Meaning:** thin pool metadata over 75 %.
**Fix:** `lvextend --poolmetadatasize +256M pve/data` (needs free VG space).

### DiskSmartFailing
**Meaning:** a disk reports SMART overall health FAILED.
**Fix:** copy the data off now and replace the disk
(`docs/runbooks/disk-rescue.md`).

### DiskPendingSectors
**Meaning:** a disk has unreadable sectors. pve3's old HDD died this way.
**Fix:** copy the data off now (`docs/runbooks/disk-rescue.md`); plan the
replacement.

### DiskReallocatedSectorsGrowing
**Meaning:** reallocated sectors grew in 24 h: the disk is degrading.
**Fix:** check backups of everything on it; plan the replacement.

### DiskHot
**Meaning:** a disk above 55 °C for 30 min.
**Fix:** airflow (laptop lid, dust). Physical: operator.

### HostCpuHot
**Meaning:** CPU package above 90 °C for 10 min.
**Check:** what is using the CPU (`top`); a transcode or build?
**Fix:** airflow, or limit the guest's cores.

### HostTextfileCollectorStale
**Meaning:** the SMART or thin-pool collector has not written for over 1 h:
the disk and pool alerts above are blind.
**Check:** `systemctl list-timers | grep -E 'smart|lvm'` on the node.
**Fix:** `ansible-playbook proxmox-nodes.yml --tags monitoring --limit <node> | cat`.

### HostSystemdUnitFailed
**Meaning:** a systemd unit is in `failed` state for 10 min.
**Check:** `systemctl status <unit>`; `journalctl -u <unit> -b`.
**Fix:** fix the cause, then `systemctl reset-failed <unit>`.

### HostClockUnsynced
**Meaning:** the node clock is not NTP-synchronised. Corosync, TLS and logs
all suffer.
**Check:** `chronyc tracking`; can the node reach the hEX NTP/DNS?
**Fix:** `systemctl restart chrony`.

### HostRebooted
**Meaning:** a node rebooted in the last 15 min. Info only.
**Check:** expected (maintenance)? If not, `journalctl -b -1 -n 50` for the
reason, and `HostOnBattery` for a power cut.

## The monitoring stack itself

### Watchdog
**Meaning:** always firing, on purpose. It pings healthchecks.io every
minute; when the pings stop, healthchecks.io alerts on its own (pve2 down,
power cut, internet down, the stack dead). It never reaches Telegram.

### PrometheusRuleFailures
**Meaning:** a rule fails to evaluate: that alert is silently broken.
**Check:** Prometheus → Status → Rules shows the error.
**Fix:** fix the rule in the repo, `make check`, `tofu apply`.

### AlertmanagerNotificationsFailing
**Meaning:** Alertmanager cannot deliver to Telegram (or healthchecks.io).
**Check:** `pct exec 120 -- journalctl -u prometheus-alertmanager -n 50`.
Token revoked? Internet down?
**Fix:** rotate/repair the secret (`docs/runbooks/secrets.md`), `tofu apply`.

### PrometheusTsdbNearRetentionCap
**Meaning:** metrics storage near the 8 GB cap: the oldest data is dropped
before 30 days. Info only.
**Fix:** if it matters, grow CT 120's disk and the cap together
(`proxmox/opentofu/monitoring.tf`, `services/monitoring/setup.sh`).

## Logs (VictoriaLogs, CT 121)

### LogsIngestionStopped
**Meaning:** VictoriaLogs received nothing for about 30 min. Every host ships
continuously, so shipping is broken.
**Check:** on a sender: `systemctl status systemd-journal-upload`; on the
hEX: `/system logging action print`. The hEX firewall rule for VLAN 20
senders: `forward_logs_ingest`.
**Fix:** restart the uploader; re-converge (`tofu apply`, Ansible
`--tags logging`).

### LogsNearDiskCap
**Meaning:** the log store is near its disk cap: the oldest days are dropped
before the 30-day retention. Info only.
**Check:** who logs the most: Grafana → Explore → VictoriaLogs:
`* | stats by (_HOSTNAME) count() hits | sort by (hits desc)`.
**Fix:** quiet the noisy service, or raise the cap and CT 121's disk together
(`services/logs/setup.sh`, `proxmox/opentofu/logs.tf`).
