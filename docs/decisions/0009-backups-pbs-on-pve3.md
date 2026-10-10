# 0009 — Backups: Proxmox Backup Server in a container on pve3, nightly, every guest

**Status:** accepted (2026-10-10)

## Context

Nothing in the lab was backed up. A dead pve2 SSD would lose Prometheus
history, the logs, every container's state and the archive's working copy.
The README's foundation rule: backups and a tested restore before any
stateful service (Postgres and Kubeletto are next).

The hardware (2026-10-10):

- **pve2:** 480 GB SSD, thin pool 71 % used; 1 TB HDD holding the archive's
  NTFS originals (mounted read-only). Every stateful guest lives here.
- **pve3:** 128 GB no-name SSD, ~50 GB free in its thin pool. **The 2.5" bay
  is empty** since its HDD failed. Only stateless guests by rule.
- Guests total ~7.5 GB of root disk. The family archive (~220 GB plus the
  re-encoded recordings) is bind-mounted into CT 110, not a guest volume.

Options considered:

- **PBS on pve2:** shares hardware with everything it protects. Rejected.
- **PBS on pve3, datastore on its SSD:** the only zero-cost option on
  different hardware from every stateful guest. It conflicts with "pve3 =
  stateless only".
- **Wait for a disk for pve3's bay:** better capacity and the only way to
  also cover the archive, but blocks all backups on a purchase.
- **Off-site (a second PBS, S3):** the eventual third copy; costs money,
  and gives nothing until a local copy exists.

PBS ships as a VM image or packages for a Debian host. Its docs do not cover
LXC, but an unprivileged container with a directory datastore is a common
community setup.

## Decision

- **PBS 4 in an unprivileged container, CT 111 `pbs` on pve3**
  (`10.10.10.14`), datastore on its 30 GB root disk. A 2 GB VM is the
  fallback if the container ever misbehaves.
- **The pve3 placement rule gets one exception:** a backup datastore holds
  copies. Losing pve3 loses no original data; losing pve2 without it would
  lose everything.
- **One cluster job, `nightly`:** 02:30 WIB, every guest (`--all`), so new
  guests are covered without anyone remembering. PBS itself is excluded:
  its disk is the datastore.
- **Retention is PBS's** (prune 7 daily / 4 weekly / 6 monthly, GC daily,
  verify weekly). The PVE storage keeps all, so there is one source of truth.
- **No client-side encryption** for this in-lab copy: a lost key loses every
  backup, and encryption pays off only when backups leave the house. Use it
  for the off-site copy.
- **Least privilege:** the cluster's token has `DatastoreBackup` only (back
  up and restore, no delete or prune).
- **Telegram gets warnings and errors only,** from PVE and PBS. Successes go
  to mail. A failed run is a notification; a guest outside the job is the
  `PveGuestNotBackedUp` alert.

## Consequences

- **The family archive is not covered.** vzdump skips bind mounts, and
  both copies of the archive are on pve2. This is the largest remaining
  risk in the lab. It closes when a disk goes into pve3's bay: second
  datastore there, then the archive copied across (file-level, e.g.
  `proxmox-backup-client` or rsync). Until then, one hardware failure on
  pve2 can still lose irreplaceable family data.
- Capacity is ~27 GB free in the datastore (2.3 GB used after the first
  run). `ThinPoolFilling` on pve3 and PBS's storage usage (`pve_disk_usage_bytes`
  for `storage/…/pbs`, `PveStorageFilling`) cap it.
- A done backup means a restore: the first one (CT 120 → a scratch CT, its
  Prometheus history checked) is recorded in `docs/runbooks/backup-restore.md`.
  Repeat it after changes to the job or datastore, and at least quarterly.
- Backup *age* is not alerted directly (pve-exporter has no metric for it).
  A failed nightly run notifies; a skipped one (job disabled, node down at
  02:30) does not. Add a freshness check if that gap ever bites.
- Off-site copy, and encryption for it: deferred until the local copy covers
  the archive.
