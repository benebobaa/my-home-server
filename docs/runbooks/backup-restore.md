# Backup and restore (PBS)

Every guest is backed up nightly at 02:30 to PBS (CT 111 on pve3, storage
`pbs`). Why and what is not covered (bind mounts — the family archive):
[ADR 0009](../decisions/0009-backups-pbs-on-pve3.md). VM 300 is no longer on
the main `pbs`: since 2026-10-28 VM 300 (both
disks, the registry's blobs on `scsi1` included) is backed up nightly to
`pbs-replica` on pve1 instead ([ADR 0025](../decisions/0025-replica-backup-of-vm-300-on-pve1.md),
amending [ADR 0021](../decisions/0021-registry-on-the-k3s-servers-own-disk.md));
checked 2026-11-06, latest copy that morning. That is the same house: no
off-site copy of VM 300 ([ADR 0032](../decisions/0032-off-site-copies-for-kubeletto-data.md);
[ADR 0034](../decisions/0034-postgres-off-site-on-b2-with-pgbackrest.md) keeps the
registry on-site and sends only Postgres off-site, below).
Restoring VM 300: [k3s-rebuild.md](k3s-rebuild.md). Service:
[`services/pbs/`](../../services/pbs/README.md).

Run commands on a node as root (`ssh root@10.10.10.12` or `.13`).

## See what exists

```bash
pvesm list pbs                       # every backup: volid, size, VMID
pvesm list pbs --vmid 120            # one guest
pvesm status --storage pbs           # storage active? how full?
pvesh get /cluster/backup/nightly    # the job
```

The PVE UI shows the same under Datacenter → Storage `pbs` → Backups, with
a **Restore** button and **File Restore** for single files.

## Back up now

```bash
vzdump <vmid> --storage pbs --mode snapshot        # one guest, on its node
vzdump --all 1 --exclude 111 --storage pbs --mode snapshot   # all guests on this node
```

## Restore a whole guest — test first, then for real

**Test restore (no risk to the live guest)** — what was done on 2026-10-10:

```bash
# on pve3 (more free thin pool than pve2)
vol=$(pvesm list pbs --vmid 120 | awk 'NR>1 {print $1}' | tail -1)   # newest
pct restore 9120 "$vol" --storage local-lvm --unique 1    # new VMID, new MAC
pct set 9120 --delete net0 --onboot 0 --hostname restore-test   # no IP clash
pct start 9120
pct exec 9120 -- curl -s '127.0.0.1:9090/api/v1/query?query=count(up)'   # data there?
pct stop 9120 && pct destroy 9120 --purge 1
```

Result then: 3.7 GiB in 45 s; Prometheus answered from data written before
the backup (26 targets at 05:30Z, pve3's boot at 22:23:54Z).

**Test restore of the K3s server, VM 300** (Kubeletto's cluster state and
secrets), done 2026-10-15 on pve2 (the only node with the thin-pool room):

```bash
vol=$(pvesm list pbs --vmid 300 | awk 'NR>1 {print $1}' | tail -1)
qmrestore "$vol" 9300 --storage local-lvm --unique 1
qm set 9300 --delete net0 --memory 1536 --balloon 0 --onboot 0 --name restore-drill-300
qm start 9300
# K3s refuses to start without a default route ("no default routes found"):
# give the NIC-less copy a black hole with VM 300's address, then run the
# server alone (with the kubelet, 1.5 GB thrashes: every platform pod starts)
qm guest exec 9300 -- sh -c 'ip link add dummy0 type dummy; ip addr add 10.10.25.20/24 dev dummy0;
  ip link set dummy0 up; ip route add default via 10.10.25.1 dev dummy0;
  systemctl stop k3s; /usr/local/bin/k3s-killall.sh;
  systemd-run --unit=k3s-drill /usr/local/bin/k3s server --disable-agent'
qm guest exec 9300 -- sh -c 'k3s kubectl get --raw /readyz; k3s kubectl -n platform get secret platform-core-env -o go-template="{{len .data}}"'
qm stop 9300 && qm destroy 9300 --purge 1 --destroy-unreferenced-disks 1
```

Result: 40 GB (81 % zeros) in 106 s; `readyz ok`; the backup of 2026-10-14
02:32 WIB had 189 tenant namespaces, 45 Knative services, 22 Secrets, and the
encrypted Secrets decrypted (platform-core-env: 61 keys; nats-auth, R2,
TLS), so the encryption key travels with the backup. Never give the copy a
real NIC: it would be a second control plane with the same address and the
tunnel's credentials.

**Real restore (the guest is broken or gone):**

1. Stop the broken guest: `pct stop <vmid>`.
2. Restore over it: `pct restore <vmid> <volid> --storage local-lvm --force 1`
   (on the node it should run on; `--force` replaces the existing disk).
3. `pct start <vmid>`; check its service and the Service dashboard.
4. Converge: `tofu plan` in `proxmox/opentofu` should be `No changes`. If
   setup steps are keyed on the container's MAC (`generation`), a restore
   with `--unique 0` keeps the MAC and nothing re-runs.

A guest that is easier rebuilt than restored (admin-gw, logs) can also just
be rebuilt with `tofu apply` (`-replace` on its module); its data is then
the backup's to restore if needed.

## Restore one app's database

Postgres (CT 130) also keeps a nightly logical dump per database on its disk,
which restores one app without touching the others:
[services/postgres → Backups and restore](../../services/postgres/README.md#backups-and-restore).

## Postgres off-site: pgBackRest in B2

The shared Postgres (CT 130) also archives WAL and takes a full backup every
3 days into a private Backblaze B2 bucket, encrypted in the CT
([ADR 0034](../decisions/0034-postgres-off-site-on-b2-with-pgbackrest.md)).
It survives losing the house; the restore window is 3-6 days, to any point
inside it, at most ~15 min of commits lost. Built by
`services/postgres/offsite.sh` (config, timers) and `offsite-job.sh`
(installed as `pg-offsite`: metrics every 5 min, a full when due at
04:00 WIB, the 10 GB guard). Stanza `main`, repo path `/pgbackrest`.

### Turn it on (once)

1. **B2 (operator, in the web UI):** an account on the free tier, no card.
   *Caps & Alerts*: every cap (storage, download, class B, class C) at **$0**.
   *Buckets → Create*: private, default encryption off (pgBackRest encrypts),
   object lock off. Its *Lifecycle Settings*: **Keep only the last version**.
   *Application Keys → Add*: one key with access to **this bucket only**,
   **Read and Write**, no file-name prefix (for CT 130); a second, same
   bucket, **Read Only** (for restores; it stays on the Mac). Note the
   bucket's endpoint (`s3.<region>.backblazeb2.com`).
2. **Secrets:** [secrets.md → the off-site backup](secrets.md#the-off-site-backup-b2-keys-and-the-cipher-passphrase).
3. **hEX:** the scrape rule for CT 130 gains port 9100 (its freshness
   metrics). Snapshot, `tofu apply` in `network/routeros`, snapshot.
4. **CT 130:** `apt-cache policy postgresql-18` in the CT first: if a new
   minor is waiting, this apply restarts Postgres too (setup.sh installs it),
   so do it in the window of step 5. Then `tofu apply` in `proxmox/opentofu`:
   `setup.sh` runs again (node_exporter on 9100, nftables; a reload), then
   `offsite.sh` writes the config and runs `stanza-create` against the
   bucket. It ends with `PENDING: archive_mode needs a PostgreSQL restart`.
5. **In an approved window** (a few seconds of refused connections):

   ```bash
   ssh root@10.10.10.12 'pct exec 130 -- bash /root/postgres/offsite.sh --restart-ok' </dev/null
   ```

   It turns `archive_mode` on, restarts, runs `pgbackrest check` (rolls back
   and restarts again if that fails), enables the timers and starts the first
   full backup in the background (`journalctl -u pg-offsite-daily -f`).
6. **Verify:** `pct exec 130 -- runuser -u postgres -- pgbackrest --stanza=main info`
   shows the full; Prometheus has `pg_offsite_repo_bytes` and
   `pg_offsite_archive_last_success_timestamp_seconds`; then a restore drill
   (below).

### Point-in-time restore into a scratch Postgres

Works anywhere with Docker and the age key (the operator Mac; after losing
the house, any machine). Uses the **read-only** key: the scratch copy cannot
write to the bucket. Tested locally 2026-11-09
([experiment](../experiments/2026-11-09-pgbackrest-offsite-local.md)).

```bash
# 1. A Debian 13 with PostgreSQL 18 and pgBackRest from PGDG, no cluster of its own.
docker run -d --name pg-restore debian:trixie sleep infinity
docker exec -e DEBIAN_FRONTEND=noninteractive pg-restore bash -c '
  apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates curl postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  echo "create_main_cluster = false" >> /etc/postgresql-common/createcluster.conf
  apt-get install -y -qq --no-install-recommends postgresql-18 pgbackrest'

# 2. Its config, from SOPS straight into the container (never on the Mac's disk).
cd ~/Documents/benelabs/homeserver/proxmox/opentofu
sops exec-env secrets.sops.env 'printf "[global]\nrepo1-type=s3\nrepo1-path=/pgbackrest\nrepo1-s3-bucket=%s\nrepo1-s3-endpoint=%s\nrepo1-s3-region=%s\nrepo1-s3-key=%s\nrepo1-s3-key-secret=%s\nrepo1-cipher-type=aes-256-cbc\nrepo1-cipher-pass=%s\nprocess-max=4\nlog-level-console=info\nlog-level-file=off\n[main]\npg1-path=/var/lib/postgresql/restore\n" \
    "$TF_VAR_postgres_b2_bucket" "$TF_VAR_postgres_b2_endpoint" "$TF_VAR_postgres_b2_region" \
    "$POSTGRES_B2_RESTORE_KEY_ID" "$POSTGRES_B2_RESTORE_APP_KEY" "$TF_VAR_postgres_offsite_cipher_pass"' \
  | docker exec -i pg-restore bash -c 'install -d -m 0750 -o postgres /etc/pgbackrest && cat > /etc/pgbackrest/pgbackrest.conf && chown postgres /etc/pgbackrest/pgbackrest.conf && chmod 0600 /etc/pgbackrest/pgbackrest.conf'

# 3. What is there, then restore to a moment (WIB here; omit --type/--target for "latest").
docker exec pg-restore runuser -u postgres -- pgbackrest --stanza=main info
docker exec pg-restore runuser -u postgres -- pgbackrest --stanza=main \
  --type=time --target='2026-11-09 18:30:00+07' --target-action=promote restore

# 4. Start it on its own: Debian keeps the config outside the data
#    directory, so give it an empty one; archiving off, no network listener.
docker exec pg-restore bash -c '
  cd /var/lib/postgresql/restore && touch postgresql.conf pg_ident.conf
  echo "local all all peer" > pg_hba.conf && chown postgres: postgresql.conf pg_ident.conf pg_hba.conf
  runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_ctl -D . -w -t 3600 -l /tmp/restore.log \
    -o "-c archive_mode=off -c listen_addresses= -c unix_socket_directories=/tmp" start'
docker exec pg-restore runuser -u postgres -- psql -h /tmp -XAtc 'SELECT pg_is_in_recovery(), now()'
docker exec pg-restore runuser -u postgres -- psql -h /tmp -d kubeletto -XAtc 'SELECT count(*) FROM <a table>'

# 5. Done (a drill): remove it.
docker rm -f pg-restore
```

- **Drill monthly** (ADR 0032): restore to "a few minutes ago", find a row
  written after the newest full, note the time it took and the download
  size here. A restore pulls a full and its WAL (1-3 GB): if B2 refuses with
  a cap error, raise the download cap for that day.
- **Getting one database back into CT 130:** `pg_dump --format=custom -d <db>`
  in the scratch copy, copy the dump into CT 130, `pg_restore --clean --if-exists -d <db>`
  (as for the [local dump](../../services/postgres/README.md#backups-and-restore)).
- **The whole house is gone:** build a new CT 130 (`tofu apply`, or by hand
  on any Debian 13), restore as above into `/var/lib/postgresql/18/main`
  with the cluster stopped (`--delta` to reuse files, `--type=default` for
  the newest), start it, then re-run `offsite.sh` (with `--restart-ok`).
  The promoted cluster has the same system id on a new timeline, so it
  archives into the same stanza; `pgbackrest check` must pass before the
  copy counts again. (Not drilled yet.)

### After a PBS restore of CT 130

A PBS copy of CT 130 holds the archive config. A **test** copy must never
reach B2 (restore it without a NIC, as above, and
`systemctl disable --now pg-offsite-metrics.timer pg-offsite-daily.timer` in
it). After a **real** PBS restore over CT 130, its WAL position is behind
what the bucket already has, and `archive-push` fails ("already exists with
a different checksum"): the database is fine, the off-site copy is not.
Then, once the restored CT is confirmed good: in the CT as `postgres`,
`pgbackrest --stanza=main stop`, `pgbackrest --stanza=main stanza-delete --force`,
`pgbackrest --stanza=main start`, then re-run `offsite.sh` (it recreates the
stanza, runs `check` and, finding no full, starts one; `--restart-ok` is not
needed, archiving is already on). This deletes the bucket's older history:
PBS holds that.

## Restore single files

PVE UI → storage `pbs` → pick the backup → **File Restore** → browse and
download. CLI equivalent from inside the PBS CT:

```bash
pct exec 111 -- proxmox-backup-client catalog dump <snapshot> --repository 'pve@pbs!cluster@localhost:main'
```

(needs the token secret; the UI is simpler.)

## If PBS itself is gone

The backups are on CT 111's root disk on pve3. Rebuild the CT with
`tofu apply` only if the volume is lost anyway; otherwise restore the CT's
disk first. The datastore survives a CT rebuild only if its volume is kept.
After a rebuild, `terraform_data.pbs_link` recreates the token and storage
entry.

## When it fails

- **Nightly job failed** → Telegram (PVE notification). Read the task log:
  PVE UI → node → Tasks, or `journalctl -u pvescheduler`.
- **Verify/GC/prune failed** → Telegram (PBS notification). In the CT:
  `proxmox-backup-manager task list`.
- **`PveGuestNotBackedUp`** → a guest is outside the job: see
  [alerts.md](alerts.md#pveguestnotbackedup).
