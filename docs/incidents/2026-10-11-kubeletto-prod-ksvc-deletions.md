# 2026-10-11: Kubeletto prod deleted tenant services on a memory-full node

| | |
| --- | --- |
| **Status** | Mitigated 2026-10-11 21:00 WIB (14:00 UTC); watched until 14:35 UTC |
| **Impact** | On the rented production server (not the lab), 17 tenant Knative Services were deleted by Kubeletto's own crash-loop suspender: 6 belonged to the tenants suspended for proxy abuse the same day, 11 to ordinary tenants. A deleted service stays down until its owner redeploys. More tenants had cold starts that never came up while it lasted. |
| **Duration** | Scheduling failures from about 12:40 UTC; deletions 13:02–14:01 UTC |
| **Trigger** | The node's memory **requests** reached 99 %, so scale-from-zero tenant pods stayed `Pending` |
| **Root cause** | A chronic capacity limit (one 16 GiB node; requests: tenants 8.2 GiB, platform 5 GiB, of which OpenObserve 2 GiB) combined with a suspender that treats any `RevisionMissing` lasting 30 min as a crash loop and deletes the KService, even when the pod simply cannot be scheduled |
| **Contributing** | Migration work from this repo: a `pg_dump` pod requesting 256 MiB ran 13:04–13:42 UTC on the full node; and deleting the abusive tenants' pods under their 0-pod quota put their services in `RevisionMissing`, so the suspender deleted those too |
| **Fix** | With the operator's yes: OpenObserve scaled to 0 (`kubectl -n openobserve scale sts openobserve --replicas=0`), memory requests 99 % → 86 %; pending pods scheduled |

## Timeline (UTC; WIB = UTC+7)

| Time | Event |
| --- | --- |
| 12:11 | The six abusive tenants are suspended in prod's database (admin kill-switch semantics). |
| 12:30 | The quota reconciler sets their pod quota to 0. |
| ~12:36 | Their running pods are deleted; Knative cannot recreate them (quota 0), so their services go `RevisionMissing`. |
| ~12:40 | First `FailedScheduling: Insufficient memory` for ordinary tenants' cold starts. |
| 12:58–13:01 | A first dump pod (256 MiB request) runs and is stopped. |
| 13:02–13:07 | The suspender deletes the six abusers' services (30 min after they went `RevisionMissing`). |
| 13:04–13:42 | A second dump pod (256 MiB request) runs; it is deleted at 13:42 (likely preempted by a higher-priority platform pod). |
| 13:32–14:01 | The suspender deletes 11 ordinary tenants' services, each 30–31 min after its pod could not be scheduled. |
| 13:52 | Noticed while checking on the dump: 308 `FailedScheduling` events in the last hour, node at 99 % memory requests. |
| 14:00 | OpenObserve scaled to 0 after the operator chose that option; 86 % requests. |
| 14:02 | Tenant pods Running again; the last deletion (14:01:39) came from a watch that started before the fix. |

## Analysis

The scheduler places pods by **requests**, not by use: the node used far less
memory than it had promised. Kubeletto's free tier gives each app 320–576 MiB
of requests, so a few cold starts in the same minutes fill the node. A pod
that cannot be scheduled leaves its Knative revision without a ready
instance (`RevisionMissing`). The crash-loop suspender cannot tell that from
a real crash loop and, after 30 minutes, deletes the service ("redeploy
required"), turning a capacity squeeze into lost deployments.

Logs before 10:05 UTC had rotated, so whether deletions also happened on
earlier days is unknown; in the 10:05–13:00 window there were none.

## Action items

- [ ] The 11 ordinary tenants need a redeploy (operator decision: redeploy for them, or tell them). The list is in prod's core logs (`KService deleted`).
- [ ] Kubeletto code: the crash-loop suspender must not count `Unschedulable` / `Insufficient` (or a quota of 0) as a crash loop. Belongs in the Kubeletto repo.
- [ ] Prod until cutover: keep OpenObserve at 0 replicas (it is dropped at the move; tenant log history and usage charts are stale meanwhile).
- [x] Operational pods on prod run without resource requests (the second dump does).
- [x] The suspension procedure in `runbooks/kubeletto-migration.md` corrected: deleting a suspended tenant's pods leads to its services being deleted.
