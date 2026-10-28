# pbs — Proxmox Backup Server

Nightly backups of every guest: CT 111 `pbs` on **pve3** (`10.10.10.14`,
VLAN 10), Proxmox Backup Server 4 on Debian 13. Why here and how:
[ADR 0009](../../docs/decisions/0009-backups-pbs-on-pve3.md). Restoring:
[docs/runbooks/backup-restore.md](../../docs/runbooks/backup-restore.md).

| | |
| --- | --- |
| Replica | CT 112 `pbs-replica` on pve1 (`10.10.10.19`): the same code with `PBS_STORE=replica`, datastore `replica`, job `replica-registry` (VM 300 incl. the registry disk, 03:30). ADR 0025. |
| UI | `https://10.10.10.14:8007` (no login set up: use the PVE UI → storage `pbs`, or `proxmox-backup-manager` in the CT) |
| Datastore | `main` at `/var/lib/proxmox-backup/datastore/main`, on the CT's 30 GB root disk (pve3's SSD) |
| Job | `nightly` (cluster backup job): 02:30 WIB, every guest except CT 111, snapshot mode |
| Retention | PBS prune job `main-daily`: 7 daily, 4 weekly, 6 monthly. PVE side keeps all (one source of truth) |
| Housekeeping | GC daily; verify job `main-weekly` Sat 04:00 (anything not verified in 30 days) |
| Failures | warnings/errors → Telegram (PVE job results via PVE notifications, PBS's own jobs via `notify.sh`); `PveGuestNotBackedUp` if a guest falls out of the job |
| Built by | `proxmox/opentofu/pbs.tf` → `setup.sh`, `notify.sh` (in the CT), `files/pbs-link.sh` (root on pve3) |

## What is and is not backed up

- **Backed up:** every guest's root disk — container config, Prometheus
  history, logs, Grafana, Tailscale state, the archive's File Browser config.
  A new guest is covered automatically (`--all`, minus PBS).
- **Not backed up: bind mounts.** vzdump skips them ("not a volume"). That is
  **the family archive itself** (`/mnt/staging/archive` and
  `/mnt/e4/_captures-30fps` on pve2, mounted into CT 110). Deliberately
  left out: the operator will delete the archive on 2026-10-12 (decided
  2026-10-10), so it gets no backup and no disk is bought for it. Only CT
  110's small root disk is in the nightly job, until the CT is removed.
- **Not backed up: PBS itself** (its disk *is* the datastore). Rebuild it from
  the repo; the backups on its disk survive a CT rebuild only if the volume
  is kept.

## Numbers (first run, 2026-10-10)

5 guests, ~7.5 GB of guest disk → 2.3 GB in the datastore (dedup + zstd).
A full run took ~1.5 min. Verify: 0 errors. Restore of CT 120 (3.7 GiB):
45 s at ~85 MiB/s.

## When the pve3 disk arrives

Add it to the CT as a mount point (root-only: a `pct set -mp…` step in
`pbs.tf`'s pattern), create a second datastore on it (`setup.sh`), point the
storage entry at it (`pbs-link.sh`), and run one backup. The old datastore can be removed after
the new one has a verified backup of every guest.

## Changing things

- **Any file here** → `tofu apply` in `proxmox/opentofu` (re-runs
  `setup.sh`; `notify.sh` re-runs with it).
- **Schedule / retention / exclusions:** `files/pbs-link.sh` (job) and
  `setup.sh` (prune, verify, GC), then apply.
- **Run a backup now:** on each node, `vzdump --all 1 --exclude 111 --storage pbs --mode snapshot`
  (or PVE UI → Datacenter → Backup → `nightly` → Run now).

## Gotchas found while building

- PBS's docs cover a VM or a physical host, not an LXC. An unprivileged CT
  (nesting on) works for a directory datastore; if it ever misbehaves, the
  fallback is a 2 GB VM.
- `proxmox-backup-manager user generate-token` has no `--output-format`; it
  prints `Result: {…}`. A token's ACL can only be set after it exists.
- The package adds the enterprise repo, which fails `apt update` without a
  subscription: `setup.sh` removes it.
- PVE's default notification matcher sent everything to Telegram, which
  would have meant a "backup OK" message every night. Telegram now gets
  warnings and errors only (matcher `telegram-failures`, PVE and PBS).
