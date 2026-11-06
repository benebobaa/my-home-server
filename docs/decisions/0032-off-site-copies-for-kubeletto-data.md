# 0032 — Kubeletto's Postgres and registry get an off-site copy

**Status:** accepted (2026-11-06), not yet built. Amends [ADR 0021](0021-registry-on-the-k3s-servers-own-disk.md) and [ADR 0025](0025-replica-backup-of-vm-300-on-pve1.md): "same site, not off-site" no longer stands for the registry. ADR 0009 (PBS main) and 0025 (the replica) stay as the on-site layer. Part of Kubeletto's operating model (`docs/design/platform-operating-model.md` in the Kubeletto repo, decision D20).

## Context

Kubeletto now has paying customers on the home platform. Its two stores that cannot be rebuilt from git are backed up only inside the house:

- **Postgres** (CT 130, shared): nightly PBS on pve3. A restore was proven on 2026-10-14. Worst case today: up to a day of data lost, and nothing survives losing the house.
- **Registry blobs** (VM 300 `scsi1`): the PBS replica on pve1 (ADR 0025). Losing them means every tenant built from source must rebuild and redeploy: a customer-visible outage, not just lost files.

ADR 0021 accepted "no backup" when the platform had no paying customers. ADR 0025 left "off-site" as a separate decision. This is that decision.

## Decision

- **Postgres:** continuous WAL archiving plus periodic base backups (pgBackRest or wal-g, chosen when built) to an S3-compatible bucket outside the house. Target: at most about 5 minutes of committed data lost, restore within 2 hours. The nightly PBS backup stays.
- **Registry:** a nightly sync of the blob store to the same off-site bucket, under a separate prefix and credentials.
- **Off-site means** a provider outside the house's power and ISP (object storage such as R2 or B2, or the planned VPS front). Encrypted at rest with a key held in SOPS, never readable by the bucket provider. Kubeletto's monthly infrastructure ceiling decides the provider.
- **Restore drills:** monthly, into a scratch instance, recorded in `docs/runbooks/backup-restore.md`. A copy that has never been restored does not count.
- **Not covered, on purpose:** Valkey (cache only, ADR 0016), VictoriaLogs and build caches (rebuildable or expiring). NATS JetStream is covered only if what it holds turns out not to be work queues; that is checked when this is built.

## Consequences

- **Upload uses the home line,** which has a monthly quota (1,500 GB on 2026-11-06). WAL is small. The registry's first full sync is about 8 GB, then deltas. Both go in the quota budget next to tenant traffic.
- **New credentials:** a write-only bucket key at home, a read key kept off the lab for restores. Rotation joins `docs/runbooks/secrets.md`.
- **An alert** when the newest archived WAL segment or the last registry sync is older than its target, routed like the PBS job alerts.

## Verification (to do when built)

- A WAL-based point-in-time restore of the Kubeletto database into a scratch Postgres, with a row written after the last base backup present in the copy.
- A registry restore from the bucket into a scratch path with the same file count and bytes as live.
- The freshness alerts fire when the jobs are stopped.
