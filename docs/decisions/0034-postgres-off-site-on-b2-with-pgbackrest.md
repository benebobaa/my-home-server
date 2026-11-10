# 0034 — The shared Postgres goes off-site to Backblaze B2 with pgBackRest; the registry stays home

**Status:** accepted (2026-11-09). Built and proven locally against a stand-in S3 server ([experiment](../experiments/2026-11-09-pgbackrest-offsite-local.md)); not live until the operator creates the bucket and approves the Postgres restart. Amends [ADR 0032](0032-off-site-copies-for-kubeletto-data.md): it fixes 0032's open choices (provider, tool) and changes two of its targets (RPO, the registry). 0032's restore-drill and alert lines stand.

## Context

- ADR 0032 decided that Kubeletto's Postgres and registry blobs get an encrypted copy outside the house, with "at most about 5 minutes" of commits lost, and left the provider and tool open, bounded by Kubeletto's monthly infrastructure ceiling.
- The goal of this lab is to cut cloud spend. Backblaze B2's free tier gives 10 GB of storage with an S3-compatible API, no money spent. It is the only constraint that matters here: anything that does not fit in 10 GB costs money.
- Measured on CT 130 on 2026-11-09: the data directory is 1.1 GB (the `kubeletto` database 953 MB, `larasrouter` 29 MB). WAL is written at about 740 MB a day raw and gzips to about 0.55 of that.
- A forced WAL switch every 5 minutes (the 0032 target) ships a full 16 MB segment each time, mostly empty but not compressible to nothing: 288 segments a day on top of the real WAL. Held for a 3-6 day window, that does not fit next to two full backups in 10 GB.
- The registry's first sync alone is about 8 GB (0032). It does not fit in the same 10 GB beside Postgres.

## Decision

1. **Provider: Backblaze B2, free tier, one private bucket**, through its S3 endpoint. The account's caps are set to $0 (storage, downloads, class B and C calls), so going over the free tier blocks instead of billing.
2. **Only Postgres goes off-site.** The registry stays on-site: VM 300's nightly PBS replica on pve1 (ADR 0025). Accepted risk: if the house is lost, every tenant built from source rebuilds and redeploys. The platform's database survives (which apps, which domains, which images to build), so recovery is rebuild work, not lost customer data.
3. **Tool: pgBackRest** from the PGDG apt repo (the repo CT 130 already uses for PostgreSQL 18). `repo1-type=s3` against B2, `compress-type=zst`, `repo1-bundle=y` (small files in bundles: fewer objects, fewer B2 calls), `archive-async=y` with a spool directory. One stanza, `main`.
4. **Encrypted in the CT:** `repo1-cipher-type=aes-256-cbc`, with a passphrase held in SOPS (`proxmox/opentofu/secrets.sops.env`) and in the operator's password manager. B2 only ever stores ciphertext; without the passphrase the bucket is unreadable, to B2 and to us.
5. **RPO about 15 minutes, not 5:** `archive_timeout = 15min`. While anything is written, a segment is shipped at least every 15 minutes.
6. **A full backup every 3 days**, by a daily systemd timer (04:00 WIB, after the 01:30 dump and the 02:30 PBS run) that backs up only when the newest full is older than ~2.75 days. **`repo1-retention-full=2`:** a restore window of 3-6 days, point in time to any moment inside it. WAL is kept from the oldest full on. Older history stays with the nightly PBS backup at home (ADR 0009), unchanged.
7. **The 10 GB guard**, kept simple, in four layers:
   - an alert at 8 GB of files in the repo (`PostgresOffsiteRepoLarge`);
   - the daily job, above 9 GB, expires down to **one** full backup and its WAL, and records it (`PostgresOffsiteGuardExpired`);
   - B2's $0 storage cap refuses writes past 10 GB, so it can never bill;
   - `archive-push-queue-max=4GiB`: if the bucket refuses or is unreachable for days, pgBackRest drops WAL rather than let it fill CT 130's 20 GB disk. The database stays up; the off-site copy gets a gap that the next full closes. The archive alert fires long before (1 h).
   B2 keeps a deleted file as a hidden version until a lifecycle rule removes it, and pgBackRest cannot see those. The bucket's lifecycle rule is "keep only the last version", which removes them after a day; the guard sits 1 GB below the cap for that day.
8. **Credentials:** two B2 application keys, both limited to this bucket. CT 130 holds a read-and-write key (pgBackRest's expire deletes, so a write-only key does not work, unlike 0032 assumed). A read-only key for restores stays in SOPS on the operator's Mac, never in the lab.
9. **Freshness** is a node_exporter in CT 130 that serves only a textfile directory (`:9100`, gated to the monitoring host like the Postgres exporter): when a WAL segment last reached the bucket (from `pg_stat_archiver`; with async archiving, `archive_command` succeeds only once the segment is stored), when the last full finished, the repo's size, when the guard last acted. Alerts: archive older than 1 h, full older than 4 days, the daily job not completing for 30 h, the repo over 8 GB, the guard having acted.
10. **Turning archiving on needs a Postgres restart.** `services/postgres/offsite.sh` never restarts on its own: OpenTofu runs it to write the config and prove the bucket (`stanza-create`), and the restart is a separate, hand-run step (`--restart-ok`) in a window the operator approves. It refuses to turn `archive_mode` on before `stanza-create` passed, and turns it off again if `pgbackrest check` fails after the restart: a failing `archive_command` fills `pg_wal`.

## Consequences

- **Size:** steady state about 4-5 GB (two fulls of roughly 0.5 GB each compressed, up to 6 days of WAL at ~0.4 GB a day, a day of hidden versions). Room for the databases to about double before the 8 GB warning. Past that, the choice is retention 1 or a paid tier, in a new ADR.
- **Upload on the home line:** about 0.4 GB a day of WAL plus a full every third day, roughly 17 GB a month against the 1,500 GB quota.
- **B2 calls:** WAL uploads are class A (free). Listing and reading (`info`, the daily size check, `check`) are class B and C, a few hundred a day at most, below the free daily allowance. With $0 caps, going over blocks those calls for the rest of the day; watch B2's usage page in the first week.
- **Restores download:** a full restore pulls a full backup and the WAL after it (1-3 GB). That may be more than B2's free daily download allowance; for a real disaster, raise the download cap for that day (cents). The monthly drill (0032) proves the restore path and measures it.
- **A PBS restore of CT 130** brings back archiving with the old WAL position, which collides with WAL already in the bucket. The copy must not reach B2: restore tests run without a NIC (as today), and after a real PBS restore the stanza is recreated (`docs/runbooks/backup-restore.md`).
- **A new scrape port:** CT 130 has two metrics ports, so its targets carry a `port` label, and the hEX scrape rule for it gains 9100.
- **The registry's off-site line of 0032 is withdrawn.** If the platform's paying load grows enough to pay for storage, it comes back as its own decision.

## Verification

- 2026-11-09, locally (Debian 13 + PGDG PostgreSQL 18 + pgBackRest in a container, SeaweedFS as the S3 stand-in): `setup.sh` then `offsite.sh` unchanged; stanza-create, the pending-restart path, `--restart-ok`, `check`, a full backup, a row written after it, a point-in-time restore into a fresh data directory with the row present, the metrics files, and the guard on a faked size. Details in the [experiment](../experiments/2026-11-09-pgbackrest-offsite-local.md).
- **To do when live:** `pgbackrest check` and the first full on CT 130; the metrics in Prometheus; a point-in-time restore from B2 into a scratch Postgres with a row written after the last full present (0032's verification line); the archive alert firing when the bucket key is revoked.

## Update, 2026-11-09 (live)

The status line above is as written when the ADR was accepted. It went live the
same evening: the operator created the bucket and keys, the hEX pinhole for the
new metrics port was applied, and `offsite.sh --restart-ok` ran in an approved
window (about 19:51 WIB). `pgbackrest check` passed, the first full backup
(`20261109-125144F`, 1006 MB database, 103 MB in the bucket) completed with no
failures, the metrics are on `:9100`, and a point-in-time restore from B2 with the
read-only key into a scratch Postgres brought back a row written after the full
(37-104 s plus about 20 s of replay, about 110 MB downloaded). The drill log is in
[backup-restore.md](../runbooks/backup-restore.md#postgres-off-site-pgbackrest-in-b2).
Not yet confirmed: B2's $0 caps (operator), a real-size drill after the next
rotation, and the archive alert firing on a revoked key.

