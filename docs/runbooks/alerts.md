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
**Check:** the Host and guest board (Infrastructure) for that host. Guest → `pct status <vmid>` on
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

## Internet quota (Biznet plan)

The line is "Home Internet 100 Mbps, 1500 GB", renewed on the 16th. The quota
counts what comes IN on ether1: 1500 GB a month is 50 GB a day. When it is gone
the line drops to 5 Mbit/s for everyone (the household and every customer)
until the renewal. On 2026-11-06 that happened after about 21 days, and the
cause was one free tenant app (see the three alerts below). Real remaining
quota: the Biznet portal (ask Biznet support for add-on prices).

### WanQuotaPaceHigh
**Meaning:** WAN inbound over the last 7 days is above 350 GB, so the month is
on pace for more than the 1500 GB plan.
**Check:** `services/kubeletto/tenant-bandwidth.sh` ranks namespaces by network
use (read-only, 60 s) and names the tenant and plan. Then Grafana, router
counters `ifHCInOctets{ifName="ether1"}`.
**Fix:** in this order. (1) Find who pulls: the script. (2) If it is one tenant
app, pause that service (customer-facing: the operator decides; `kubectl delete
ksvc` keeps its settings and a redeploy brings it back) and tell the owner.
(3) Only if the traffic is legitimate, buy extra quota or a bigger tier from
Biznet; do not buy it to pay for one runaway app. Design: operating model D17
(Kubeletto repo, `docs/design/platform-operating-model.md`).
If it fires again with legitimate traffic, it is also the trigger for
Kubeletto's VPS front (D27): put it on the weekly queue.

### WanInboundDayHigh
**Meaning:** WAN inbound over the last 24 h is above 60 GB (the plan allows
about 50 GB a day).
**Check / Fix:** as `WanQuotaPaceHigh`: something is pulling hard right now.

### TenantWorkerInboundSustained
**Meaning:** the Kubeletto tenant worker (k3s-worker) has received more than
2.5 Mbit/s from the internet for 2 hours (about 27 GB a day, over half the
plan from tenant pods alone).
**Check:** `services/kubeletto/tenant-bandwidth.sh`. A tenant pod that appears
and disappears every couple of minutes is a scale-to-zero app being woken by a
pinger or a kiosk page: look at its request rate in `usage_samples`
(`http_requests`, per service) and its pods
(`kubectl -n <ns> get pods` over a few minutes).
**Fix:** as `WanQuotaPaceHigh`. The free tier's per-pod cap is 2 Mbit/s, so one
app can still pull about 4 Mbit/s with two pods overlapping.

## Proxmox cluster

### PveClusterNotQuorate
**Meaning:** the three-node cluster lost quorum (two nodes are down). Guests keep running. Starting,
stopping and configuring guests, and backups, are locked.
**Check:** `pvecm status` on a surviving node. Which nodes are gone?
**Fix:** bring a node back, one is enough (`docs/runbooks/proxmox-cluster.md`). Only
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
nightly job (`nightly`, PBS) covers every guest except the two PBS CTs
(`pbs`, `pbs-replica`: their disks are the datastores) and VM 300 (its own job
`replica-registry`), so a new guest is covered automatically. The rule skips
guests named `pbs*`; the job's exclusion list is `PBS_EXCLUDE` in
`proxmox/opentofu/pbs.tf`, so a new deliberate exclusion needs the rule
(`rules/cluster.yml`) and `tests/backups.test.yml` updated with it. This fires
if the job was edited, disabled or removed. It checks coverage only, not
whether the last run worked.
**Check:** `pvesh get /cluster/backup/nightly` on a node; is the guest
excluded? `pvesm status --storage pbs` — is the storage active?
**Fix:** re-converge: `tofu apply` in `proxmox/opentofu` (`terraform_data.pbs_link`
re-creates the job). See `docs/runbooks/backup-restore.md`.

### BackupStale
**Meaning:** a guest that a backup job is meant to cover has no good snapshot
newer than 36 h in that job's storage (the nightly job runs at 02:30, the
registry replica at 03:30; a healthy guest is under 25 h). One night was
missed. A guest with no snapshot at all alerts 36 h after it was first
expected. The series come from `ansible/files/backup-freshness.py` on pve2
(`prometheus-node-exporter-backup.timer`, every 10 min): the expected guests
are the cluster's own backup jobs (`all` minus `exclude`, or the `vmid` list)
over the live guest list, so a deleted guest or a changed exclusion stops
being expected by itself. A snapshot whose PBS verification failed does not
count. History: 2026-10-27 to 11-12 the nightly backups of CT 101 and CT 132
failed every night (pve3's thin pool full) and nothing but Telegram's
per-run errors noticed.
**Check:** the labels name the guest and the storage. The failed run is in
the node's task list (`pvesh get /cluster/tasks`, or UI → node → Task
History, type "Backup"). `pvesm status --storage pbs` (is it active and not
full?), `lvs pve` on the guest's node (a data pool near 100 % cannot take the
snapshot), and `ssh root@10.10.10.12 /usr/local/sbin/backup-freshness --out -`
prints what the collector sees.
**Fix:** clear the cause (fstrim the guests, `docs/runbooks/node-ops.md`;
free PBS space: prune/GC, `services/pbs/README.md`), then run it by hand:
`vzdump <vmid> --storage <storage> --mode snapshot`. The alert resolves on
the next collector run (10 min).

### BackupMetricsMissing
**Meaning:** Prometheus has had no `homelab_backup_*` series for 2 h, so
`BackupStale` cannot fire.
**Check:** pve2 up? `systemctl list-timers | grep backup` on pve2;
`/var/lib/prometheus/node-exporter/backup.prom` exists? A pve2 outage also
shows as `PveNodeDown`.
**Fix:** `ansible-playbook proxmox-nodes.yml --tags monitoring --limit pve2 | cat`.
If monitoring moved to another node (`lab.yaml`), converge both nodes: the
collector follows `lab.hosts.monitoring.node`, and the old node's
`backup.prom` must be removed by hand or the series double.

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
**VM 300 `/mnt/registry`:** those fixes do not apply. It holds the registry's
only copy of its blobs and has no backup ([ADR 0021](../decisions/0021-registry-on-the-k3s-servers-own-disk.md)),
so never delete files there by hand. Garbage collection needs the registry
read-only or stopped, and retention is off; plan it as in the
[retention dry run](../experiments/2026-10-15-registry-retention-dry-run.md).
Until then, the fix is to grow `scsi1` in `proxmox/opentofu/k3s.tf` and extend
the ext4 filesystem.

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
**Meaning:** CPU package above 90 °C for 10 min, on any Proxmox node: Intel's
`coretemp` (pve2, pve3) or AMD's `k10temp` (pve1), chosen by hwmon chip name
(NVMe and ACPI sensors do not count).
**Check:** what is using the CPU (`top`); a transcode, a build, or on pve1 the
GPU VM's load? Reference: pve1's 20-min GPU + CPU soak peaked at 89 °C
(`services/ai/README.md`), so a sustained 90 means more than that test did.
**Fix:** airflow, or limit the guest's cores. The Ryzen throttles at 95 °C.

### HostTextfileCollectorStale
**Meaning:** the SMART, thin-pool or backup-freshness collector has not
written for over 1 h: the disk, pool and backup alerts are blind.
**Check:** `systemctl list-timers | grep -E 'smart|lvm|backup'` on the node
(the backup collector runs on pve2 only; `journalctl -u prometheus-node-exporter-backup`
says why a run failed: usually `pvesh` cannot reach PBS).
**Fix:** `ansible-playbook proxmox-nodes.yml --tags monitoring --limit <node> | cat`.
**Known cause (pve2/pve3, after a power cut):** the laptops lose their RTC
without AC and boot at 2026-04-14. The SMART collector runs before chrony
steps the clock, so its file carries an April mtime and looks 200 days old.
It clears by itself when the timer runs again, 15 min after boot
([2026-11-04](../incidents/2026-11-04-power-cut.md)).
**Known cause (pve1, found 2026-10-14):** Debian's SMART timer runs only when
`/dev/sd*` or `/dev/hd*` exists, and pve1 has NVMe only: the timer never fired
by itself, and the alert came from the one file the installer's USB disk left.
A drop-in (`prometheus-node-exporter-smartmon.timer.d/nvme.conf`, Ansible
`monitoring` tag) adds `/dev/nvme*`. Verify on a node: `systemctl cat
prometheus-node-exporter-smartmon.timer | grep nvme` and the age of
`/var/lib/prometheus/node-exporter/smartmon.prom` is under 15 min.

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

## Kubernetes and Kubeletto

Alerts about the Kubeletto K3s cluster (`k3s`, `k3s-worker`) and about
Kubeletto as a service. Commands that need `kubectl` go through VM 300's
guest agent (`qm guest exec 300 -- k3s kubectl ...` on pve2).

### K8sPodUnschedulable
**Meaning:** the scheduler of the Kubeletto cluster (`k3s`, `k3s-worker`)
refused a pod for 5 min: no node has room. A tenant app or a build cannot
start. Scale-from-zero Pending (image pull, seconds) does not count: only a
pod the scheduler marked unschedulable does.
**Check:** `kubectl get pods -A --field-selector status.phase=Pending`, then
`kubectl describe pod -n <ns> <pod>` (Events: `Insufficient memory` or a
taint/selector mismatch). Through VM 300's guest agent, as in
`services/kubeletto/apply.sh` (the API is not reachable from the LAN).
**Fix:** `Insufficient memory` is D9 (Kubeletto `docs/migration`): requests
are overcommitted on the 4 GB worker. See also K8sNodeMemoryRequestsHigh.
Find what holds the reservation (`kubectl describe node k3s-worker`,
Allocated resources); the lasting fix is the growth path (a bigger or second
worker), not raising limits. A selector/taint cause means a platform pod
lost its `control-plane` nodeSelector or toleration: platform pods must
carry both (they only reach Postgres from `k3s`).
**Background:** on 2026-10-11 the rented server sat at 99 % memory requests,
tenant pods went Pending and 17 services were deleted by the crash-loop
suspender (`docs/incidents/2026-10-11-kubeletto-prod-ksvc-deletions.md`). At
home the fixed suspender is live since 2026-11-09 (Kubeletto D28): it pauses
only services whose pods really crash-loop, not ones stuck Pending, so the
tenant outage remains.

### K8sNodeMemoryRequestsHigh
**Meaning:** pods on a node reserve over 90 % of its allocatable memory
(sum of memory requests of Running and scheduled Pending pods) for 15 min.
Free RAM can look fine: the scheduler counts requests, not use. The next
cold start or build may not fit; it is the warning before
K8sPodUnschedulable.
**Check:** `kubectl describe node k3s-worker` (Allocated resources),
`kubectl top pods -A --sort-by=memory` for real use against requests.
**Fix:** Kubeletto's home request shares are already low (memory 15 %,
builds 250m/512Mi, queue-proxy 32Mi: Kubeletto `e8f37aee`). Nothing to
restart. If tenants really grew, the growth path is D9: 16 GB SODIMM for
pve3, or a second worker on pve2 once CT 110 is gone. pve1 is not an option
(on demand, ADR 0012).

### K8sNodeCapacityTrigger
**Meaning:** severity info, not an incident. Pods on a node have reserved over
85 % of its allocatable memory at every 30-minute reading for 7 days. This is
Kubeletto's Phase 3 trigger for removing hard-coded node IPs and adding a node
(operating model D27, Kubeletto repo `docs/design/platform-operating-model.md`).
**Check:** as `K8sNodeMemoryRequestsHigh`, and whether the growth is paying
tenants (worth a node) or idle free ones (pause them instead).
**Fix:** raise it at the operator's next weekly session (Kubeletto
`docs/ops/weekly-queue.md`) with the D22 growth plan. Nothing to do tonight.

### K8sNodeMemoryPressure
**Meaning:** the kubelet reports `MemoryPressure=true` on a node for 2 min:
it is short of memory and evicts pods (BestEffort first, then those over
their request). Tenant apps are being killed.
**Check:** `kubectl describe node <node>` (Conditions, Events: `Evicted`,
`EvictionThresholdMet`), `kubectl get pods -A | grep Evicted`, and
`free -m` in the VM through the guest agent.
**Fix:** find what grew (`kubectl top pods -A --sort-by=memory`); a runaway
tenant is stopped by suspending the tenant
(`docs/runbooks/kubeletto-migration.md`, "Suspending a tenant"), not by
restarting the node. The evicted pods are recreated by Knative on demand.
Lasting fix: D9.

### KubelettoPublicPathDown
**Meaning:** from the internet (the monitoring host, through Cloudflare),
`api.kubeletto.com/healthz` is not 200 (`instance=kubeletto-api`), or the
registry's token endpoint `/v1/registry/auth` does not answer core's own 401
JSON (`kubeletto-registry-auth`), for 5 min. Customers see it: the console
and CLI fail, and new image pulls of platform-built apps fail.
**Check:** `probe_http_status_code{job="blackbox_public"}`; by hand:
`curl -si https://api.kubeletto.com/healthz`. A Cloudflare 52x page: the
tunnel or cloudflared (`k3s kubectl -n cloudflared get pods`); a 404 or a
foreign page: the DNS record (`network/cloudflare/flip.sh forward` dry run
shows where the three records point); a timeout: Traefik or core
(`HttpProbeFailed` on k3s fires too if core is down).
**Fix:** by cause; the DNS records are code (`network/cloudflare`).

### K8sPlatformPodNotReady
**Meaning:** a platform pod on the K3s cluster (core, NATS, Valkey, the
registry, Traefik, Kourier, Knative, cloudflared, logs, kube-system; never a
tenant `kl-*` or build pod) has run for 10 min without passing its readiness
probe. Deploys, builds or traffic through that component fail.
**Check:** `qm guest exec 300 -- k3s kubectl -n <namespace> describe pod <pod>`
(Events, Readiness), and its logs. The registry: pushes and pulls; NATS:
core's event flow; cloudflared: every public request.
**Fix:** the component's own problem (its logs say which); `kubectl -n <ns>
rollout restart deploy/<name>` once the cause is gone.

### K8sPlatformPodWaiting
**Meaning:** a platform container cannot start for 10 min: `CrashLoopBackOff`,
`ImagePullBackOff`/`ErrImagePull` (registry or Docker Hub unreachable, a
removed tag), or `CreateContainerConfigError` (a Secret or ConfigMap missing,
e.g. after a `secrets.sh` run).
**Check:** the `reason` label; `kubectl -n <ns> describe pod <pod>`; for a
crash loop `kubectl -n <ns> logs <pod> --previous`.
**Fix:** by reason: restore the missing object (`services/kubeletto/secrets.sh`),
the image (pin, registry), or the crash (logs).

### K8sPlatformPodRestarting
**Meaning:** a platform container restarted more than twice in 30 min (a
node reboot restarts each once). Often OOM (limit too small) or a failing
liveness probe.
**Check:** `kubectl -n <ns> describe pod <pod>` (Last State: `OOMKilled`?),
`logs --previous`.
**Fix:** the cause; a memory limit in the Kubeletto home overlay if it is OOM.

### K8sTenantColdStartChurn
**Meaning:** one tenant namespace started more than 200 distinct pods in 24 h
(info; it feeds the weekly review). A scale-to-zero app that something pings
every few minutes (an uptime pinger, a kiosk page, a cron) starts a fresh pod
each time: about 715 a day means one request every two minutes. On 2026-11-06
six free tenants were over the line (240 to 715 a day); one of them pulled 40-50
GB a day from the internet, the others cost CPU and startup churn but little
bandwidth.
**Check:** `services/kubeletto/tenant-bandwidth.sh` for whether it costs
bandwidth (`TenantWorkerInboundSustained` is the alert that says so); the
request rate in `usage_samples` (`http_requests`, per service); pods over a few
minutes (`kubectl -n <ns> get pods`).
**Fix:** none by itself. If it also pulls a lot, treat it as
`WanQuotaPaceHigh`. A longer Knative scale-down delay would turn the cycling
into one warm pod (a memory cost on the 4 GB worker): a platform decision, not
an alert response.

### K8sTenantContainerRestarting
**Meaning:** a tenant's app container (`user-container`) restarted more than 10
times an hour, summed over the namespace, for 3 hours: a crash loop, not a
deploy. On 2026-11-06 one free tenant had restarted about 7,000 times in 21
days (a Django app without its required `DJANGO_SECRET_KEY`), and nothing had
said so.
**Check:** `kubectl -n <ns> logs <pod> -c user-container --previous` for the
error; `kubectl -n <ns> get events` for quota errors (a namespace at its Services
or ephemeral-storage quota cannot replace pods).
**Fix:** the owner's: tell them what the log says. The platform's crash-loop
suspender (`CRASH_LOOP_SUSPEND_ENABLED`, off at home until the operator turns it
on) pauses such a service and emails the owner (Kubeletto ticket RUNTIME-001,
operating model D18). Pausing by hand is `kubectl delete ksvc <svc> -n <ns>`:
customer-facing, the operator's call.

### K8sTenantNamespaceWithoutNetworkPolicy
**Meaning:** a tenant namespace (`kl-*`) has no `kubeletto-base-policy`. That
policy blocks every private range and the household's public address for the
tenant's pods. The router's worker pinholes to Postgres 5432 and Valkey 6381
apply to every pod on the worker, so without the policy that namespace's pods
can try the shared data stores (only `pg_hba` and the Valkey password remain).
Critical. Needs kube-state-metrics to export `networkpolicies` (Kubeletto
overlay `kube-state-metrics.yaml`); until it does, the alert cannot fire.
**Check:** `kubectl -n <ns> get networkpolicy`. A namespace seconds old is
normal (the alert waits 15 min); a missing policy after that means core's
quota/policy reconciler did not run for it (core logs, `internal/quota`).
**Fix:** re-apply the policy (redeploy the service, or core's quota sync); if
it cannot be fixed quickly, pause that tenant's services. Customer-facing:
the operator decides.

### K8sTenantLogsThrottled
**Meaning:** Vector's per-tenant cap (Kubeletto `infra/k8s/home/vector.toml`,
`kubeletto_throttle_runtime`: 6000 events per 10 s per tenant per node)
dropped runtime log lines on that node. The tenant's `kubeletto logs` has
holes for that window; its app is unaffected.
**Check:** which tenant: `vector_component_discarded_events_total{component_id="kubeletto_throttle_runtime"}`
by its per-key label in Prometheus; then that tenant's log rate in
VictoriaLogs (`tenant_id:<id> | stats count()` over 1 min).
**Fix:** a runaway logger is the tenant's to fix (tell them); a legitimate
volume is a reason to raise `threshold` in `vector.toml` and re-apply
`services/kubeletto/apply.sh platform`.

### K8sLogsDropped
**Meaning:** Vector lost log events by failure (`intentional="false"`), not by
a filter or the throttle: usually the VictoriaLogs sink rejecting or timing
out.
**Check:** `kubectl -n logs logs <vector pod> | grep -E 'ERROR|WARN'`, and
whether `victorialogs-0` in `logs` is running and has disk.
**Fix:** the sink's cause (VictoriaLogs down or full); the lost lines do not
come back.

### KubelettoUsageMeterStale
**Meaning:** a Kubeletto usage meter (`http_requests`, `log_bytes`; Kubeletto
D11) has not recorded a window for 30 min. Healthy lag is 7-13 min (5-minute
windows, read 2 min after they close). Until it catches up, the request and
log caps and the tenants' usage page stand still. A meter with no checkpoint
at all is `KubelettoUsageMeterMissing`.
**Check:** core's log for `usage meter` lines (`kubectl -n platform logs
deploy/platform-core | grep 'usage meter'`): a failing collect names
VictoriaLogs, a failing commit names Postgres. Then `victorialogs-0` in `logs`
and CT 130. The position: `SELECT * FROM usage_meter_checkpoints;` in the
`kubeletto` database. Only the worker leader runs the meters: check that one
holds the lock (core logs `leader-only background loops started`).
**Fix:** the cause; the meter then catches up by itself from its checkpoint,
up to 24 h back (VictoriaLogs keeps 7 days). A gap older than 24 h is skipped
and logged, never invented. Never edit the checkpoint by hand to "skip
ahead" unless you mean to leave that window unmetered.

### KubelettoUsageMeterMissing
**Meaning:** core's `/metrics` (the `k3s` target, port 30080) answers, but one
meter (the `meter` label: `http_requests` or `log_bytes`) has had no checkpoint
series for 30 min: core was deployed without `VICTORIALOGS_URL`, or the meter
never started. Nothing is metered, so the request and log caps and the tenants'
usage page do not move. When the endpoint itself is down, `TargetDown` fires
and this alert stays quiet; a meter that reports an old checkpoint is
`KubelettoUsageMeterStale`.
**Check:** which meters exist: `kubeletto_usage_meter_processed_until_seconds`
in Prometheus. Then core's setup and log: does the deployment set
`VICTORIALOGS_URL` (`kubectl -n platform get deploy platform-core -o yaml`; it
may come from a Secret), and `kubectl -n platform logs deploy/platform-core |
grep -E 'usage meter|leader-only'`. Only the worker leader runs the meters.
**Fix:** a missing setting: restore it in the Kubeletto home overlay (or its
secrets, `services/kubeletto/secrets.sh`) and re-apply
(`services/kubeletto/apply.sh platform`); core restarts on the rollout and the
meter starts from its checkpoint. If the setting is there, the startup log
names why the meter did not start.

## Kubeletto payments

The core's payment log lines are counted by Vector in the cluster
(`kubeletto_payment_events_total{event=...}`, Kubeletto `infra/k8s/home/vector.toml`)
and the rules are `rules/kubeletto-payments.yml`. They replace eight
OpenObserve alerts that the move home removed. To read the lines themselves:
`ssh root@10.10.10.12 'qm guest exec 300 --timeout 60 -- sh -c "k3s kubectl -n platform logs deploy/platform-core --since=30m | grep -i payments"'`.
If the counters look empty while payments clearly happen, check that Vector is
scraped (`up{job="service_dmz"}`) and that `kubeletto_payment_events_total`
exists at all in Prometheus: a rename of a log message in the core silently
zeroes its counter (the strings are pinned in `vector.toml`'s unit tests, which
cannot see the core).

### KubelettoPaymentPaidNoPlan
**Meaning:** SumoPod says a payment completed, but the core could not match it
to an order or activate it, or the customer paid less than the plan price: money
taken, no plan granted. Critical; the baseline is zero. It keeps firing for 6 h
so a night-time message is still there in the morning.
**Check:** the core log lines `reconcile manually` and `refusing to activate plan`
(they carry the order id and tenant); then the `payments` row for that order
(`status`, `amount_idr`, `expires_at`) in the Kubeletto database.
**Fix:** reconcile by hand: confirm the payment in the SumoPod dashboard, then
grant the plan the way `activatePlan` does (a `tenant_plan_assignments` update
plus the audit row) or ask SumoPod to resend the webhook once the cause is
fixed. Tell the customer. Money and customer-facing: the operator's call.

### KubelettoPaymentWebhookFailed
**Meaning:** the webhook handler failed to process a `payment.completed` event
and returned an error. SumoPod retries, and every retry fails until the cause is
fixed; a paying customer may have no plan meanwhile. Critical.
**Check:** the core log for `webhook completion processing failed` (the error is
on the line); a database blip shows in Postgres alerts at the same time.
**Fix:** fix the cause (database, a migration the binary is ahead of); SumoPod's
retry then completes the payment. If it does not retry, resend it from the
SumoPod dashboard (runbook in Kubeletto CONSOLE-021).

### KubelettoPaymentsReconcilerStale
**Meaning:** the hourly plan-expiry reconciler logs "sweep completed" even when
idle and none was counted for 150 minutes: renewal reminders, expired-checkout
emails and lapse downgrades have silently stopped. Critical. Note it also fires
when the counter is absent, for example right after Vector restarts, until the
next heartbeat (at most an hour; `for: 15m` plus the window avoids most of that).
**Check:** the platform-core pod (`kubectl -n platform get pods`) and its log
for `plan expiry reconcile sweep`; whether Vector is up (`TargetDown` for
service_dmz would fire too).
**Fix:** restart the core pod if it is wedged (`kubectl -n platform rollout
restart deploy/platform-core`; old pods serve until the new one is ready).

### KubelettoPaymentWebhookSignatureRejected
**Meaning:** three or more webhook signature checks failed in 15 minutes. Probes
of the public endpoint cause one or two; a rotated or mistyped
`SUMOPOD_WEBHOOK_SECRET` would drop every real payment silently.
**Check:** `client_ip` on the `webhook signature rejected` log lines (one scanner
address is noise; SumoPod's own address failing is the fault); the secret in the
cluster (`platform-core-env`, key names only) against the SumoPod dashboard.
**Fix:** correct the secret and roll the core; ignore a lone scanner.

### KubelettoPaymentGatewayUnavailable
**Meaning:** creating a QRIS payment link failed twice or more in 15 minutes, so
customers cannot start a payment ("payment provider is unavailable").
**Check:** SumoPod's status; the core log for `gateway create payment failed`
(the error says timeout, 401 or 5xx); the DNS or egress path from the DMZ if it
is a timeout (ADR 0031, 0033).
**Fix:** wait out SumoPod; a 401 means `SUMOPOD_API_KEY` is wrong or revoked.

### KubelettoPaymentSeatCheckFailed
**Meaning:** the Pro seat-capacity check failed closed, so checkout answers 503
for everyone until it clears; usually a database blip.
**Check:** Postgres CT 130 alerts at the same time; the core log for `seat check failed`.
**Fix:** fix the database; the alert clears by itself.

### KubelettoPaymentPlanAtCapacity
**Meaning:** a customer tried to buy Pro and was refused because every seat
(`plan_limits` `max_active_seats`) is taken. Not a fault: lost revenue.
**Check:** `SELECT value_numeric FROM plan_limits ... key = 'max_active_seats'`
against the paying count (the weekly review, section 7), and the node headroom
(`K8sNodeCapacityTrigger`, the Kubeletto board).
**Fix:** raise the cap with a migration if the nodes have room (operator's yes:
money and capacity) and write to the customer who was turned away.

### KubelettoPaymentDowngradeRestoreFailed
**Meaning:** a lapse downgrade, a restore after renewal, or a whole reconcile sweep
failed for at least one service. By design these steps log and continue, so the
plan row can look right while the running workload was never clamped (after a
lapse) or never restored (after a renewal).
**Check:** the core log lines `downgrade:` or `restore:` with `failed` (tenant and
service ids on the line); whether the service is paused or still at the old size.
**Fix:** a later reconcile pass retries snapshots left active; if it keeps
failing, fix the cause the line names (an image gone, no runtime room) or
redeploy the service by hand.

## GPU (pve1's RTX 3060, in the `ai` VM)

Metrics come from nvidia_gpu_exporter in `ai` (`:9835`, ADR 0014); the
GPU row of Infrastructure → **Hardware health** shows them. While pve1
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
**A second path:** if Telegram is what broke, this alert cannot reach you
through Telegram. Alertmanager therefore also calls the `/fail` endpoint of the
healthchecks.io check (`homelab-watchdog`), whose own Telegram integration is an
independent route to you (ADR 0036). You will see healthchecks.io report the
check **down** and, within about two minutes (the next Watchdog ping), **up**
again. That down-then-up is this alert: the Watchdog itself is fine, Telegram
delivery from Alertmanager is not. It repeats at most hourly while the alert
fires. Routing was tested live on 2026-11-09 with a test alert sent only to
this path; that the Telegram messages from healthchecks.io arrived is for the
operator to confirm.
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

## Trace store (CT 122)

### TracesNearDiskCap
**Meaning:** the trace store holds about 14.5 GiB of its 16 GiB cap for an
hour: the oldest days are dropped before the 30-day retention. Info only.
**Check:** the board Observability → **Log and trace stores**: the stored share of
the cap, and the rows dropped by reason.
**Fix:** a sender that writes too much (sample on the app side), or raise the
cap and CT 122's disk together (`services/traces/setup.sh`,
`proxmox/opentofu/traces.tf`).

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

### PostgresDatabaseLarge
**Meaning:** one app's database passed 5 GB (`pg_database_size_bytes`). Nothing
is broken: it is the point to plan growth. For larasrouter that is about a
million inference requests (~5 KB each, most of it ledger postings, which are
kept forever), half the size at which its high-volume tables are worth
partitioning.
**Check:** which tables: in the CT, as `postgres`, in that database:
`SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10`;
the disk: `df -h /` (20 GB, shared with every app).
**Fix:** grow the disk (`disk_gb` in `proxmox/opentofu/postgres.tf`, online) or
give the app its own Postgres, so it cannot fill the others' disk. For
larasrouter: decide the retention of raw usage and plan monthly partitions of
`inference_requests`, `usage_events`, `usage_settlements`, `ledger_transactions`
and `ledger_postings` by id range (row ids are UUIDv7 since larasrouter PR #131).

### PostgresDatabaseGrowingFast
**Meaning:** a database grew more than 1 GB in the last 24 hours. For
larasrouter that is roughly 200k requests a day; at that rate CT 130's free
disk lasts weeks, and this fires long before `PostgresDiskFilling`.
**Check:** is it real traffic or a runaway (a retry loop, a test against
production)? larasrouter: `SELECT date_trunc('hour', dispatch_intent_at), count(*) FROM inference_requests WHERE dispatch_intent_at > now() - interval '1 day' GROUP BY 1 ORDER BY 1`;
which tables grew: the `PostgresDatabaseLarge` query above.
**Fix:** a runaway: stop its source. Real growth: as `PostgresDatabaseLarge`,
sooner.

### Off-site copy (pgBackRest → B2)

[ADR 0034](../decisions/0034-postgres-off-site-on-b2-with-pgbackrest.md). All
warnings: the database is fine, the copy that survives losing the house is
late. The jobs' output is in the CT's journal
(`journalctl -u pg-offsite-daily -u pg-offsite-metrics`, and Postgres's own
log for `archive_command` failures: `journalctl -t postgres | grep -i archive`).
Run commands in the CT as `postgres`:
`pct exec 130 -- runuser -u postgres -- pgbackrest --stanza=main info`.

### PostgresOffsiteArchiveStale
**Meaning:** no WAL segment reached the bucket for over an hour (normal: at
most 15 min, `archive_timeout`). Committed data since then exists only at
home. Segments wait in `pg_wal` (`pg_offsite_archive_ready_segments`);
past 4 GiB pgBackRest drops them to keep the disk from filling, and the
off-site copy then has a gap until the next full backup.
**Check:** `pgbackrest --stanza=main check` (it forces a segment switch and
waits for it in the bucket); the error says what is wrong: B2 unreachable
(the home line, `HostUnreachable` on the hEX), the key revoked or the B2
cap reached (403), the bucket gone.
**Fix:** what the error names. A rotated key: [secrets.md](secrets.md#the-off-site-backup-b2-keys-and-the-cipher-passphrase).
Once `check` passes the queue drains by itself. If segments were dropped
(`pgbackrest` warned "dropped WAL file(s)" in the Postgres log), run a full
now: `systemctl start pg-offsite-daily` only runs one when due, so
`runuser -u postgres -- pgbackrest --stanza=main --type=full backup`.

### PostgresOffsiteFullBackupOld
**Meaning:** the newest full backup in the bucket is over 4 days old (one is
taken every third day at 04:00 WIB). The restore window shrinks; WAL alone
still restores, from the older full.
**Check:** `systemctl status pg-offsite-daily`, `journalctl -u pg-offsite-daily -n 50`.
**Fix:** what the log names, then `systemctl start pg-offsite-daily`.

### PostgresOffsiteDailyFailing
**Meaning:** the daily job (full backup when due, repo size, the guard) has
not completed for 30 h. The repo size and full-backup metrics are stale.
**Check / Fix:** as `PostgresOffsiteFullBackupOld`.

### PostgresOffsiteRepoLarge
**Meaning:** the repo holds over 8 GB of B2's 10 GB free tier (steady state
~4-5 GB). At 9 GB the daily job expires down to one full backup
(`PostgresOffsiteGuardExpired`); at 10 GB B2's $0 cap refuses writes and the
archive stops.
**Check:** `pgbackrest --stanza=main info` (sizes per backup); has a database
grown (`PostgresDatabaseLarge`), or is the WAL rate up (a bulk load, a
runaway)? B2's web UI shows the bucket's size including hidden versions;
if that is much larger than the repo, the lifecycle rule ("keep only the
last version") is missing.
**Fix:** a one-off (a bulk load): nothing, the next fulls expire it. Lasting
growth: decide in an ADR (retention 1, or a paid tier).

### PostgresOffsiteGuardExpired
**Meaning:** the repo passed 9 GB and the daily job expired it down to one
full backup and its WAL. The restore window is 0-3 days instead of 3-6
until it shrinks back. Fires for a day.
**Check / Fix:** as `PostgresOffsiteRepoLarge`.

## NATS (CT 131)

NATS itself down, or up without JetStream, is `HttpProbeFailed` on
`http://10.10.20.22:8222/healthz?js-enabled-only=true`: check
`pct exec 131 -- systemctl status nats` and VictoriaLogs
`_stream:{_HOSTNAME="nats"}`; fix with `systemctl start nats` (a config error
is in the journal: `nats-server -c /etc/nats/nats.conf -t` tests it).

### NatsAccountStorageHigh
**Meaning:** an app's account stores more than 80 % of its JetStream
`max_file` (`local.nats_accounts` in `proxmox/opentofu/nats.tf`) for 30 min.
Real bytes, not the streams' reservations. At 100 % its publishes are refused.
**Check:** which stream grew: `curl -s 'http://10.10.20.22:8222/jsz?accounts=true&streams=true'`
from the CT, or `jetstream_stream_total_bytes` in Grafana.
**Fix:** usually the app's own retention (a stream without `max_age` or
`max_bytes`, a consumer that never acks). Raise `max_file` in `nats.tf` only
if the growth is real, within the server's 10 GB and the CT disk.

### NatsConsumerBacklog
**Meaning:** a durable consumer has more than 1000 messages pending for
15 min: its app stopped consuming.
**Check:** the labels name the account, stream and consumer; then the app's
logs (Kubeletto: core's, in VictoriaLogs).
**Fix:** restart or repair the consumer's app. A poison message that is
redelivered forever goes to the app's dead-letter stream if it has one.

### NatsDiskFilling
**Meaning:** CT 131's root disk (the JetStream file store) is over 80 %
full.
**Check:** `du -sh /var/lib/nats/jetstream/*` in the CT (one directory per
account).
**Fix:** as `NatsAccountStorageHigh`; or grow `disk_gb` in `nats.tf`
(in place, online).

## Valkey (CT 132)

### ValkeyDown
**Meaning:** an instance's exporter cannot reach it (`redis_up 0`) for
2 min; its app has no cache, locks or rate limits (Kubeletto's core also
refuses to start without it). Severity from the tier.
**Check:** `pct exec 132 -- systemctl status valkey-server@<app>` (on pve3);
VictoriaLogs `_stream:{_HOSTNAME="valkey"}`.
**Fix:** `systemctl restart valkey-server@<app>`. It holds no data, so a
rebuild of the CT (`tofu apply -replace=module.valkey...`) is always safe.

### ValkeyMemoryFull
**Meaning:** an instance is above 95 % of its `maxmemory` for 15 min. With a
`volatile-*` policy, keys without a TTL are never evicted: once they fill
the cap, writes fail with `OOM command not allowed`.
**Check:** `INFO memory` and `INFO keyspace` on the instance (expires vs
keys: many keys without a TTL is an app bug).
**Fix:** the app's TTLs; or raise `maxmemory` in `local.valkey_instances`
(`proxmox/opentofu/valkey.tf`) within the CT's 256 MB.

## larasrouter (a Kubeletto tenant)

The LLM API router (`services/larasrouter`, namespace `kl-f42a6fae-f42a6fae`,
public name `api.larasrouter.com`). Its traffic is low-volume, so
the rules are built for low volume and use only what Prometheus already has:
Traefik's request counters for the domain's own Traefik service (one
IngressRoute, `dom-b5f3066c-…`) and kube-state-metrics, plus a few app log
events that Vector in the cluster counts as `larasrouter_events_total{event=...}`
(an allow-list in the kubeletto repo's `infra/k8s/home/vector.toml`:
`llm.provider.platform_rejected`, `routing.breaker.changed`,
`routing.partner_spend.exceeded`, `routing.partner_spend.check_failed`).
Other per-event signals (billing holds written off, routing refresh failed,
stale FX rate) are not metrics yet: add them to that allow-list first.
Kubectl through VM 300: `qm guest exec 300 -- k3s kubectl -n kl-f42a6fae-f42a6fae ...` on pve2.

### LarasrouterProviderRejected
**Meaning:** an upstream LLM supplier answered 401, 402 or 403 to
larasrouter's **own** credential in the last 10 minutes: our prepaid balance
there ran out, or the key is wrong, revoked or out of scope. The app logs
`llm.provider.platform_rejected` once per rejected attempt; Vector counts it
and `larasrouter:events:new_10m` catches the first one ever (the series is
created by that event). Critical: pages at any hour. `keep_firing_for: 1h`
holds a one-off. Routing fails over to the next deployment, so customers may
see nothing until every supplier for that model is refused: do not wait for
`LarasrouterErrorRatioHigh`.
**Check:** which supplier. In the API pods' logs (`kubectl -n
kl-f42a6fae-f42a6fae logs -l serving.knative.dev/service --since=1h -c
user-container | grep platform_rejected`): `upstream.status_code` (402 is
balance, 401/403 the key) and `routing.provider` / `routing.deployment`. A
`routing.breaker.changed` line with `routing.transition` `disabled` names the
deployment the router has taken out. The supplier's own dashboard shows the
balance.
**Fix:** top up the supplier's balance, or rotate the key (the deployment's
`api_key_env` secret on the larasrouter service) and redeploy. The breaker
re-admits the deployment after its open period. If a supplier cannot be fixed
soon, disable that deployment (`deployment_overrides`, owner's call) so no
request waits on it.
**Not firing when it should:** Vector's exporter (`:30598`, `TargetDown` for
`k3s`) or a renamed event in the app (the counter then stays at zero
silently).

### LarasrouterErrorRatioHigh
**Meaning:** more than 5 % of the API's requests in the last hour got a 5xx
(404s left out: bot and probe scans outnumber real calls), with at least 20
requests and 3 errors in that hour. Warning, 10 min of `for`.
**Reading it:** Traefik's metric code is what the client was sent, except that
a client which cancels an upload part-way shows as a **502** here (Vector's
rewrite to 499 only touches the logs; `larasrouter-5xx-reading` in the
operator's notes, RCA 2026-11-07). Those are a handful a week from one client,
well under the guards: over 30 days of this series the highest 1-hour ratio
with the guards met was 4.6 % (the 2026-11-07 DeepSeek incident). So a firing
alert is usually real. First 5xx of a status code that never occurred before
is not counted (a new series starts at 1).
**Check:** the API pods' logs for the hour (`kubectl logs -l ... --since=1h`,
look for `error.code` and the provider that failed), and the Kubeletto Metrics
tab for the service (the `client_aborted` rows are the cancelled uploads).
**Fix:** an upstream provider failing every attempt: routing weights or a
disabled deployment (owner's call); a bad release: roll back the revision.

### LarasrouterNoReadyPods
**Meaning:** no `user-container` in the namespace has been ready for 5 min, so
the API cannot answer. It runs two pods, and Knative keeps the old revision
serving during a rollout, so a deploy does not trip it. Critical: it pages
at any hour (a paid API that answers nothing). If the tenant is ever
changed to scale to zero, this rule must go (it would fire whenever the app
is idle).
**Check:** `kubectl -n kl-f42a6fae-f42a6fae get pods,revision`, then describe
the newest pod (image pull, scheduling, probes). `K8sPodUnschedulable` and
`K8sNodeMemoryPressure` explain a cluster-wide cause.
**Fix:** roll back to the previous revision, or fix what blocks the pod.

### LarasrouterPodCrashLooping
**Meaning:** a container of the namespace has been in CrashLoopBackOff for 5
min. The generic `K8sTenantContainerRestarting` is the 3-hour net for every
tenant; this is the fast one for the API.
**Check:** `kubectl logs --previous` of the crashing container: a missing
secret, an unreachable Postgres or Valkey (`PostgresDown`, `ValkeyDown`), or a
bad image.
**Fix:** at the source; a bad new revision is rolled back.

### LarasrouterEdgeMetricsMissing
**Meaning:** Prometheus has had no request counters for the domain's Traefik
service for 1 h, so `LarasrouterErrorRatioHigh` is blind. The usual cause is a
recreated custom domain (its IngressRoute name, and with it the service name
hash, changed); a scrape failure is `TargetDown` for the `k3s` target. Info.
**Fix:** `kubectl -n traefik get ingressroute | grep dom-`, find the one with
``Host(`api.larasrouter.com`)`` and put its name into the `exported_service`
match in `rules/app-larasrouter.yml` (and its test).

## Service level objectives

The one SLO ([ADR 0036](../decisions/0036-observability-v2-generated-dashboards-and-alert-contract.md),
decision 6): the **Kubeletto public API is up 99.5 % of the time over 30 days**.
The error budget is the other 0.5 %: 3 h 36 min of failure in 30 days.

- **SLI:** `min(probe_success{job="blackbox_public"})`, one sample a minute.
  The service is up at a moment when *both* public probes answer
  (`kubeletto-api`, the `/healthz` of the API, and `kubeletto-registry-auth`,
  the registry's token endpoint). One probe down is the service down.
  Traefik 5xx is not the SLI: an upload the client cancels shows as a 502.
  A minute with no probe sample (the monitoring host was off) counts as
  neither up nor down. The probes only exist since the cutover (about 25
  days), so the 30-day figures describe the history there is.
- **Burn rate** = error ratio over a window / 0.005. 1 spends exactly the budget
  over 30 days; 14.4 spends 2 % of it in an hour; 6 spends 5 % in 6 hours.
- **The alerts** (`rules/slo.yml`, tests in `tests/slo.test.yml`) need a long
  and a short window both over the line: the long one says the budget is really
  going, the short one lets the alert stop soon after the outage does.

| Alert | Burn over | And over | Held | Severity | Budget spent in the long window |
| --- | --- | --- | --- | --- | --- |
| `KubelettoErrorBudgetBurnFast` | 1 h > 14.4 | 5 min | 2 min | critical | 2 % |
| `KubelettoErrorBudgetBurnMedium` | 6 h > 6 | 30 min | 15 min | critical | 5 % |
| `KubelettoErrorBudgetBurnSlow` | 3 d > 1 | 6 h | 1 h | warning | 10 % |

**Reading it on the boards.** The Kubeletto board (Applications), row *Error
budget and burn rate*: *Error budget left, 30 days* is what is still
unspent (0 % = the objective is missed); *Burn rate against the alert lines*
draws the 1 h, 6 h and 3 d burn rates with dashed lines at 14.4, 6 and 1 (the
1 h line against 14.4, the 6 h against 6, the 3 d against 1; the top of the
chart is clipped at 20, the tooltip has the number); *Availability, 30 days,
against the objective* is the same history as a percentage against 99.5 %. The
Overview has one tile, *Kubeletto error budget* (red under 25 %). The
*Availability, 24 h / 7 d* tiles at the top of the Kubeletto board average each
probe on its own and take the weaker, so they read better than the SLI
whenever the two probes fail at different times.

**`KubelettoPublicPathDown` is the fast, binary companion**: a warning after
5 minutes of either probe down, with no memory. In a total outage it fires
about 5 minutes in, `KubelettoErrorBudgetBurnFast` about a minute later and
`KubelettoErrorBudgetBurnMedium` about 25 minutes in. The
burn-rate alerts say how much the outage cost, and catch what a 5-minute rule
cannot: an outage that is over, or a path that fails a minute in every few.

### KubelettoErrorBudgetBurnFast
**Meaning:** over the last hour the public probes failed so often (at least 5
failed minutes in the hour; burn over 14.4) that more than 2 % of the 30-day
error budget has gone, and they are failing in the last 5 minutes too, so it is
happening now. At this pace the whole budget is gone in 2 days. Customers see
the console, the CLI or image pulls fail. Fires after 5 failed minutes plus the
2-minute hold.
**Check:** `KubelettoPublicPathDown` is firing too and its section has the
causes. On the Kubeletto board: *Public probes: up or down* (which probe is
red), *Core ready* (platform or path: green means the line, Cloudflare, the
tunnel or DNS), then Network → Reachability and *Router and WAN*, since the
probe crosses the household line twice. By hand:
`curl -si https://api.kubeletto.com/healthz`.
**Fix:** the cause, as for `KubelettoPublicPathDown`. The alert clears about 5
minutes after the probes recover; the budget it cost stays spent and shows in
*Error budget left, 30 days*.

### KubelettoErrorBudgetBurnMedium
**Meaning:** over the last 6 hours the probes failed for at least 11 minutes
(burn over 6, more than 5 % of the budget) and also in the last 30 minutes. At
this pace the budget is gone in 5 days. It pages although the outage may be
over by the time you read it: an outage of 11 minutes or more fires it 15
minutes later, and it clears 30 minutes after the last failure. It also fires
for a path that keeps failing in small pieces, which `KubelettoPublicPathDown`
never sees.
**Check:** *Public probes: up or down* over the last 6 hours: one long hole is
an outage, repeated short holes are a flaky path (the tunnel, Cloudflare, the
household line, Network → *Router and WAN*). *Burn rate against the alert
lines*: the 6 h line against 6. If the probes are green now, the question is
what the outage cost: *Error budget left, 30 days*.
**Fix:** the cause. Nothing to do if it is already fixed: it clears when the
30-minute window is clean. An outage worth keeping gets a note under
`docs/incidents/`.

### KubelettoErrorBudgetBurnSlow
**Meaning:** over the last 3 days the probes failed more often than 99.5 %
allows (burn over 1, more than 10 % of the budget in 3 days) and the last 6
hours are no better, so at this pace the 30-day budget runs out before the 30
days do. A warning (held 23:00-07:00 WIB): a leak, not an outage. It fires
once the outages of 3 days add up to 22 minutes or more, so one 25-minute
outage is enough, and it then clears about 6 hours after the last failure.
**Check:** *Burn rate against the alert lines*: the 3 d line against 1. The
*Public probes* panel with the time range at 3 days: holes at the same time of
day point to a schedule (a restart, a backup filling the line), random holes to
the path. The ISP quota throttle (`WanQuotaPaceHigh`, *Router and WAN*) slows
the line that the probes cross twice.
**Fix:** remove the cause of the leak. If the cause cannot be removed and the
objective is wrong for this setup, change the objective with a new ADR; do not
silence the alert.
