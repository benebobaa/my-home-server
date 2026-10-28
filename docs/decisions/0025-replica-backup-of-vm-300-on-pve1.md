# 0025 — A replica backup server on pve1 holds VM 300, registry blobs included

**Status:** accepted (2026-10-28). Amends [ADR 0021](0021-registry-on-the-k3s-servers-own-disk.md): the registry's blobs now have a backup, though not one off-site. The rest of ADR 0021 stands. ADR 0009 stands: PBS main on pve3 keeps every other guest.

## Context

The registry's blobs live on VM 300's second disk, `scsi1` (40 GB, 8 GB used). ADR 0021 left that disk out of the PBS backup because the main datastore (on pve3, 30 GB, 5 GB free) had no room. So the registry had no backup at all, and losing pve2's SSD would have cost the images of the services built from source. pve1 is now always on ([ADR 0023](0023-pve1-always-on-ai-vm-on-demand.md)), and its NVMe has about 290 GB free on the thin pool.

## Decision

- **A second PBS server, `pbs-replica`, on pve1:** CT 112 at `10.10.10.19` (VLAN 10), 2 cores, 2 GB, a 150 GB root disk that holds the datastore `replica`. It is the same server code as `pbs` (`services/pbs/setup.sh`, with `PBS_STORE=replica`), built by `proxmox/opentofu/pbs-replica.tf`.
- **A backup job, `replica-registry`:** VM 300 only, 03:30, snapshot mode, storage `pbs-replica` (keep-all on the PVE side, pruned by PBS: 7 daily, 4 weekly, 6 monthly).
- **The main nightly job excludes 111, 112 and 300.** The replica's datastore is CT 112's root disk, so without the exclusion the main job would copy it into the 5 GB datastore. VM 300 moves to the replica for the same reason.
- **VM 300's `scsi1` (the registry disk) gets `backup = true`.** Applied after the replica job had run once, so the flag change is verified against a working path.

## Consequences

- **Not off-site.** Both backup servers sit in the same house. This protects against losing an SSD or a node, not against fire or theft. An off-site copy is a separate decision (the UPS and off-site items in the README's foundation list).
- **The replica is a stateful guest on pve1.** It breaks the old "stateful guests on pve2" placement rule on purpose: it is a backup target, and its disk is the NVMe that pve1 has now.
- **Not yet notified:** the replica's own PBS jobs (verify, prune, GC) do not go to Telegram. The PVE side of its backup job does, through the notification system. Wiring `notify.sh` for the replica is a follow-up.
- **The replica is not itself backed up.** Its datastore is its disk. Rebuild it from the repo, as for PBS main (services/pbs/README.md).
- **VM 300's root disk is now backed up by the replica, not by main.** Main keeps its existing snapshots until they prune away.

## Verification

- 2026-10-28, datastores and jobs: `datastore list` on CT 112 shows `replica`. The storage `pbs-replica` is active. The job `replica-registry` is 03:30 for VM 300. The job `nightly` excludes 111, 112 and 300, and the main datastore stayed at 5.1 GB free throughout.
- Manual backup of VM 300 to the replica, root disk only (before the flag change): 40 GiB in 148 s. A second manual backup with `scsi1` included: 40.8 GiB transferred in 109 s, and the snapshot is 85.9 GB across both disks.
- Restore test: the snapshot `2026-10-28T13:52:36Z` restored to a scratch VM with no start, no network and autostart off. Its registry disk mounts read-only with the `registry` label, ext4, 7.9 GB and 6,884 files. The live disk has 6,884 files and 7.9 GB. The scratch VM was then destroyed.
- Still to prove: the first scheduled run at 03:30 (2026-10-29), and an off-site copy, which is a separate decision.
