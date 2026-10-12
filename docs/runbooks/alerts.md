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

### RemoteAccessDown
**Meaning:** both Tailscale subnet routers (`admin-gw` on pve3, `admin-gw2`
on pve2) have been unreachable for 3 min. Nothing in the lab is reachable
remotely. One gateway down is only `HostUnreachable` (warning): the pair
fails over.
**Check:** from home (VLAN 40 or the OOB port), `pct list` on both nodes.
Both nodes down at once → power (`HostOnBattery`, healthchecks.io).
**Fix:** start or restart the gateways (`pct start 101` on pve3,
`pct start 102` on pve2); a gateway that is up but degraded needs its
`tailscaled` restarted (`services/admin-gw/README.md`). Physical access may
be needed: the operator.

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
**Meaning:** a node is offline in the cluster. Severity follows the node's
tier: pve2/pve3 are critical; pve1 is best-effort and is off by design
(ADR 0012), so for it this is a silent note, not a fault. While it fires,
the node's own and its guests' `HostUnreachable`, `TargetDown`,
`HttpProbeFailed` and `PveGuestDown` are suppressed.
**Fix:** as `HostUnreachable` for that node; then wait for `Quorate: Yes`.
For pve1: nothing, unless you meant it to be up — wake it
([node-ops](node-ops.md#wake-pve1)).

### PveGuestDown
**Meaning:** a guest with `onboot=1` is not running.
**Check:** `pct status <vmid>` / `qm status <vmid>`; the start log with
`pct start <vmid> --debug`.
**Fix:** start it. If it was stopped on purpose, set `start_on_boot = false`
in its Tofu definition instead of leaving the alert.

### PveGuestNotBackedUp
**Meaning:** a guest is in no backup job, so it has no backups at all. The
nightly job (`nightly`, PBS) covers every guest except PBS itself, so a new
guest is covered automatically. This fires if the job was edited, disabled
or removed.
**Check:** `pvesh get /cluster/backup/nightly` on a node; is the guest
excluded? `pvesm status --storage pbs` — is the storage active?
**Fix:** re-converge: `tofu apply` in `proxmox/opentofu` (`terraform_data.pbs_link`
re-creates the job). See `docs/runbooks/backup-restore.md`.

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
**On `k3s` / `k3s-worker`** (job `service_dmz`): Kubeletto's tenant requests
are overcommitted (Kubeletto docs/migration D9), so this is the warning
before the kubelet evicts tenant apps (it evicts at ~100 Mi available).
Check `kubectl top pods -A --sort-by=memory` and
`kubectl describe node k3s-worker` (Allocated, Conditions). Short term:
nothing to restart — find the app that grew. Lasting fix: the D9 growth
path (a bigger or second worker), not raising requests.

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

## GPU (pve1's RTX 3060, in the `ai` VM)

Metrics come from nvidia_gpu_exporter in `ai` (`:9835`, ADR 0014); the
**Nvidia GPU Metrics** dashboard (Grafana → Homelab) shows them. While pve1
is off there is no data and nothing fires. Live view: `ssh ai nvtop`.

### GpuHot
**Meaning:** the GPU at 83 °C or more for 5 min. The card slows itself down
from about 83 °C and shuts down near 93 °C, so long runs get slower.
**Check:** `ssh ai nvidia-smi` (temperature, fan %, power); what is running;
the dashboard's temperature and fan history.
**Fix:** airflow: dust in the GPU cooler or case filters, a stopped fan, a
hot room, the PC's side against a wall. Physical: operator. Meanwhile a
lower power limit cools it at a small speed cost:
`ssh ai sudo nvidia-smi -pl 140` (resets at boot).

### GpuHardwareSlowdown
**Meaning:** the board forced the GPU clocks down for 5 min: over
temperature (`hw_thermal_slowdown`) or the power supply asserting the power
brake (`hw_power_brake_slowdown`). The normal 170 W power cap does not fire
this.
**Check:** the dashboard's clock-event reasons panel: thermal or power brake?
`ssh ai nvidia-smi -q -d PERFORMANCE`.
**Fix:** thermal → as `GpuHot`. Power brake → the PSU (model not recorded
yet, `docs/hardware.md`) or its PCIe power cable cannot keep up: check the
8-pin connector is seated, use a dedicated cable from the PSU, and record
the PSU model; until then `nvidia-smi -pl 140` lowers the draw.

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

## PostgreSQL (CT 130)

### PostgresDown
**Meaning:** the exporter in CT 130 cannot reach PostgreSQL (`pg_up 0`) for
2 min. Every app with a database is failing. Severity from the tier
(`standard` → warning; `critical` once apps depend on it). If the exporter
itself is down too, it is `TargetDown`; if the CT is gone, `PveGuestDown`.
**Check:** `pct exec 130 -- systemctl status postgresql@18-main`; its log:
`journalctl -t postgres -n 50` in the CT, or VictoriaLogs
`_stream:{_HOSTNAME="postgres"} SYSLOG_IDENTIFIER:=postgres`. A full disk
stops it too (`PostgresDiskFilling`).
**Fix:** `systemctl start postgresql@18-main`. If it will not start, read the
log first: a corrupt data directory means a restore
([services/postgres](../../services/postgres/README.md#backups-and-restore)).

### PostgresDiskFilling
**Meaning:** CT 130's root disk (data, WAL, the last 3 dumps) is over 80 %
full. At 100 % every write fails.
**Check:** in the CT: `du -sh /var/lib/postgresql /var/backups/postgres`;
which database: `SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database`.
**Fix:** grow the disk: `disk_gb` in `proxmox/opentofu/postgres.tf`,
`tofu apply` (in place, online). Then find out why it grew.

### PostgresConnectionsHigh
**Meaning:** more than 80 % of `max_connections` (100) are in use for 10 min.
New connections are refused soon.
**Check:** who holds them: `SELECT usename, application_name, state, count(*) FROM pg_stat_activity GROUP BY 1, 2, 3 ORDER BY 4 DESC`.
**Fix:** usually an app leaking connections or a too-large pool: fix the
app's pool size. Raise `max_connections` (`setup.sh`) only with memory to
match.
