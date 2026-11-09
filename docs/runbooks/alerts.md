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
Also **KubelettoUsageMeterMissing** (same runbook).
**Meaning:** a Kubeletto usage meter (`http_requests`, `log_bytes`; Kubeletto
D11) has not recorded a window for 30 min. Healthy lag is 7-13 min (5-minute
windows, read 2 min after they close). Until it catches up, the request and
log caps and the tenants' usage page stand still. *Missing*: core's `/metrics`
answers but has no checkpoint for a meter (deployed without
`VICTORIALOGS_URL`, or the meter never started).
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
**Meaning:** the SMART or thin-pool collector has not written for over 1 h:
the disk and pool alerts above are blind.
**Check:** `systemctl list-timers | grep -E 'smart|lvm'` on the node.
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

## Trace store (CT 122)

### TracesNearDiskCap
**Meaning:** the trace store holds about 14.5 GiB of its 16 GiB cap for an
hour: the oldest days are dropped before the 30-day retention. Info only.
**Check:** the dashboard *Trace store (VictoriaTraces)*: the stored share of
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
