# pgBackRest off-site backup, proven locally (2026-11-09)

Question: do `services/postgres/setup.sh` + `offsite.sh` (ADR 0034) build a
working pgBackRest setup against an S3 bucket, refuse to turn archiving on
before the bucket works, never restart Postgres without `--restart-ok`, and
does a point-in-time restore bring back a row written after the last full?
Nothing live was touched: no CT 130, no B2.

## Setup

- **"CT 130":** a Debian 13 (`debian:trixie`) container on the operator Mac
  (OrbStack), running systemd as PID 1 (`--privileged`, host cgroups), so the
  scripts' `systemctl` calls are real. The repo's `services/postgres/` was
  streamed in exactly as `terraform_data.postgres_setup` does (`tar` →
  `/root/postgres`), and `setup.sh <container-ip> <its /24> <a fake monitoring ip>`
  run, then `offsite.sh`. Result: PostgreSQL 18.6 (PGDG, `18.6-1.pgdg13+2`),
  pgBackRest 2.60.0 (PGDG), node_exporter 1.9.0 (Debian).
- **"B2":** MinIO was the plan, but its images and binaries are no longer
  published (Docker Hub `minio/minio` denied, `dl.min.io` answers 410
  Gone). The stand-in is SeaweedFS's S3 gateway (`chrislusf/seaweedfs`,
  `server -s3`), on HTTPS with a self-signed certificate (pgBackRest's S3
  driver speaks HTTPS only), one bucket `pgbr-test`, a read/write identity
  and a read-only one.
- `offsite.sh`'s stdin: the six real keys with test values, a random
  48-byte cipher passphrase, plus the test-only `S3_URI_STYLE=path` and
  `S3_VERIFY_TLS=n` (never set for B2).

Test-environment quirks, not findings about the scripts: `setup.sh`'s
`flush ruleset` also removes Docker's embedded-DNS NAT rules inside a
container, so the container was given `nameserver 8.8.8.8` and a hosts entry
for the S3 stand-in. A first `apt-get` hung on a stalled connection and was
killed.

## Commands

From the repo root on the Mac (test-only credentials; the scratchpad
directory `$S` holds the certificate and the stdin file):

```bash
# S3 stand-in, HTTPS on 443 (small volumes: the defaults returned HTTP 500,
# "no free volumes left")
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=s3 -addext subjectAltName=DNS:s3 -keyout $S/key.pem -out $S/cert.pem
docker network create pgbr-net
docker run -d --name pgbr-s3 --hostname s3 --network pgbr-net --ip 192.168.148.3 -v $S:/certs:ro chrislusf/seaweedfs:latest   server -dir=/data -volume.max=50 -master.volumeSizeLimitMB=64 -s3 -s3.port=443   -s3.cert.file=/certs/cert.pem -s3.key.file=/certs/key.pem -s3.config=/certs/s3.json   # two identities: read/write, read-only
docker exec pgbr-s3 sh -c 'echo "s3.bucket.create -name pgbr-test" | weed shell'

# "CT 130": Debian 13 with systemd as PID 1 (image: debian:trixie + systemd)
docker run -d --name pgbr-pg --hostname postgres --network pgbr-net --privileged --cgroupns=host   -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock pgbr-test:trixie
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C services/postgres -cf - .   | docker exec -i pgbr-pg sh -c 'rm -rf /root/postgres && mkdir -p /root/postgres && tar -xf - -C /root/postgres'
docker exec pgbr-pg bash /root/postgres/setup.sh 192.168.148.2 192.168.148.0/24 192.168.148.100

# stdin: B2_KEY_ID, B2_APP_KEY, B2_BUCKET=pgbr-test, B2_ENDPOINT=s3, B2_REGION=us-east-1,
#        CIPHER_PASS=$(openssl rand -base64 36), S3_URI_STYLE=path, S3_VERIFY_TLS=n
docker exec -i pgbr-pg bash /root/postgres/offsite.sh < $S/stdin.env          # → PENDING
docker exec pgbr-pg bash /root/postgres/offsite.sh </dev/null                 # reuse config → PENDING
docker exec pgbr-pg bash /root/postgres/offsite.sh --restart-ok </dev/null    # → live, first full

# Rows around a target time, then a segment switch
psql -d kubeletto -c "INSERT INTO drill (note) VALUES ('AFTER-BACKUP row: must survive PITR')"
psql -XAtc "SELECT now()"                                                     # → the target
psql -d kubeletto -c "INSERT INTO drill (note) VALUES ('AFTER-TARGET row: must NOT be in the copy')" -c "SELECT pg_switch_wal()"

# Restore: a fresh container per docs/runbooks/backup-restore.md (read-only identity), then
pgbackrest --stanza=main --type=time --target='2026-11-09 10:37:59.006464+00' --target-action=promote restore

# Guard (in pgbr-pg, after a second full)
PG_OFFSITE_FAKE_REPO_BYTES=9500000000 /usr/local/sbin/pg-offsite daily
```

(`psql` and `pgbackrest` above run in the container as `postgres`:
`docker exec pgbr-pg runuser -u postgres -- ...`.)

## Results

| Step | Result |
| --- | --- |
| `setup.sh` on a fresh container | **Failed at first:** `start_inputs` ran `cat` on two files that do not exist yet, and under `pipefail` that ended the run. A latent bug (CT 130 was built before that function existed); a rebuild of CT 130 would have stopped there. Fixed (`|| true`, same hash when the files exist, so no restart on the live CT). Then: `postgres setup complete (18.6 ..., UTF8 b C.UTF-8)` |
| node_exporter, textfile only | `:9100` serves `node_textfile_scrape_error 0` and the `pg_offsite_*` files, no host collectors; nftables: `tcp dport { 9100, 9187 } ip saddr <monitoring> accept`, then drop |
| `offsite.sh` with the S3 server failing (HTTP 500) | `stanza-create` failed after its retries; `offsite: stanza-create failed: archive_mode stays off`; exit 1; `archive_mode` off, no `conf.d/offsite.conf`, timers not enabled |
| `offsite.sh` (no flag), bucket working | `stanza-create ... completed successfully`; `PENDING: archive_mode needs a PostgreSQL restart`; exit 0; `archive_mode` off; timers disabled |
| Re-run with stdin, and with no stdin (`</dev/null`, reuses the config) | Same result; `pg_postmaster_start_time()` unchanged (10:31:29) across all three: **no restart**. The no-stdin run first failed (`V: unbound variable`, an empty array under `set -u`); fixed |
| `offsite.sh --restart-ok` | Restart (postmaster 10:35:09), `archive_mode on`, `archive_timeout 15min`, `archive_command pgbackrest --stanza=main archive-push %p`, `check command end: completed successfully`, both timers enabled, first full started in the background |
| First full (`pg-offsite-daily`) | `full backup size = 44.5MB, file total = 1271`, repo backup set **5.4 MB** (zst + aes-256-cbc), `pgbackrest info`: `cipher: aes-256-cbc`, `status: ok` |
| Bucket unreachable (S3 container stopped), WAL switch | After 60 s `archive command failed with exit code 82` in the journal; `pg_stat_archiver.failed_count` 1, `last_archived_time` **did not move**, segment `.ready` in `pg_wal`. So with `archive-async`, `last_archived_time` means "in the bucket", not "queued": the right source for the freshness metric |
| Bucket back | Segment archived within a minute, `pg_offsite_archive_last_success_timestamp_seconds` advanced, ready 0 |
| Point-in-time restore | Row `AFTER-BACKUP` (id 200002, 10:37:55) inserted after the full; target time 10:37:59; row `AFTER-TARGET` (10:38:02); `pg_switch_wal()`. In a **second, fresh** Debian 13 container built with the runbook's commands, config from stdin with the **read-only** identity: `restore --type=time --target=... --target-action=promote` (5.4 s), started with an empty `postgresql.conf`, `archive_mode=off`. Log: `recovery stopping before commit of transaction 773, time 10:38:02`, `selected new timeline ID: 2`. `pg_is_in_recovery()` f, timeline 2; **`AFTER-BACKUP` row present, `AFTER-TARGET` row absent** (count 0), 200002 rows |
| Daily job, full not due | `newest full is 0 h old: none due`; `pg_offsite_repo.prom` written |
| Guard, faked size (`PG_OFFSITE_FAKE_REPO_BYTES=9500000000`, two fulls in the repo) | `GUARD: repo holds 9500000000 bytes (> 9000000000): expiring down to one full backup`, `remove expired backup 20261109-103511F`, WAL `...04` to `...08` removed; `pgbackrest info`: one full; `pg_offsite_guard_last_expire_timestamp_seconds` set. Next real run: repo **6.3 MB** (from 12.9 MB) |
| Metrics on `:9100` | `pg_offsite_archive_last_success_timestamp_seconds`, `_archive_failed_total`, `_archive_ready_segments`, `_full_backup_last_timestamp_seconds`, `_full_backups`, `_repo_bytes`, `_guard_last_expire_timestamp_seconds`, `_daily_last_success_timestamp_seconds` |
| Timers | `pg-offsite-metrics.timer` every 5 min; `pg-offsite-daily.timer` 21:00 UTC (04:00 WIB) |
| Files | `/etc/pgbackrest/pgbackrest.conf` 0640 root:postgres; secrets shown as `<redacted>` in every pgBackRest log line; `/var/log/pgbackrest` empty (`log-level-file=off`) |
| Last run, the committed files | Same sha256 as the repo; `setup.sh` and `offsite.sh` re-run on the live-archiving container: no restart, `archiving to the bucket is live` |

Checked separately: PGDG's `postgresql@.service` (postgresql-common
293.pgdg13+1) sets no `PrivateTmp`, so `archive_command` and a
`pgbackrest stop` run over `pct exec` share pgBackRest's default lock
directory `/tmp/pgbackrest`; the `stop` steps in the runbooks reach the
archiver.

Containers, network and the test images were removed afterwards.

## Not tested here

- **B2 itself:** its S3 dialect, the application-key capabilities, the $0
  caps, the lifecycle rule, the daily class B/C allowance. Only the live
  run shows those (ADR 0034, "To do when live").
- That the read-only key **cannot write**: the restore used it, but a write
  attempt failed for an unrelated reason (no primary cluster), so the
  refusal itself is unproven.
- The rollback when `pgbackrest check` fails right after the restart (the
  stand-in could not be made to pass `stanza-create` but fail `check`).
- `archive-push-queue-max` dropping WAL past 4 GiB.
- A restore at real size (1.1 GB data, days of WAL) and its download time.
