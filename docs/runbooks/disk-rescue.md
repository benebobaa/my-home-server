# Runbook: rescuing files from a failing HDD

**Applies to:** any old disk attached to a node before it is reused. First
written for the two 1 TB Toshiba laptop HDDs (2026-10-08), one of which
(pve3, serial `…X8PEW8QJT`) failed during the first read-only scan.

## Rule: image first, never file-copy a failing disk

A disk with **any** `Current_Pending_Sector` is a rescue source, not a storage
target. pve3's went 8 → 888 → 7,704 → 8,448 in four hours of light reading,
with bad sectors spread over the whole surface. File-level copies (rsync,
`du`, `find`) seek all over the file table and hammer the weak areas;
`ddrescue` reads sequentially, skips bad areas and resumes from its mapfile.

Do **not** run a SMART long test on such a disk: it reads the whole surface
and returns no data.

## Procedure

1. **Stop touching it.** Unmount everything, then `hdparm -y /dev/sdX` (standby)
   between steps.
2. **Cap drive-side retries:** `smartctl -l scterc,30,30 /dev/sdX` (3 s per
   sector; it resets at power-off).
3. **Staging space with sparse-file support** on a healthy disk (ext4 does sparse files;
   NTFS via ntfs3 does **not**). 2026-10-08: a thin LV on pve2
   (`lvcreate -V 290G -T pve/data -n rescue-staging`, ext4, mounted at
   `/mnt/staging` with `discard`). Mount it on the failing node over sshfs:
   `sshfs -o reconnect,ServerAliveInterval=15 root@<peer>:/mnt/staging/<dir> /mnt/<x>`.
   Test sparse with a 1 GB `ddrescue --sparse` of `/dev/zero`; `du` must show 0.
4. **Used-cluster domain per NTFS partition** (images only what is allocated):
   `ddru_ntfsbitmap /dev/sdXN sdXN.domain`. If it hangs (bad `$MFT` start:
   kill it after 2 min) or reports `total= 0 bytes`, read the bitmap directly
   (the offset and size are on its `ddrescue -i… -s…` command line) and use
   `scripts/rescue/ntfs-bitmap-domain.py`. No usable bitmap → image the whole
   partition.
5. **Image, most valuable partition first**, mapfile on the staging side:
   ```sh
   ddrescue -d -b 4096 -n -T 2m --sparse -m sdXN.domain /dev/sdXN sdXN.img sdXN.map
   ```
   `-n` skips scraping; `-T 2m` exits after 2 minutes without a successful
   read. Without `-T`, the sda2 run ground the dead file-table zone for
   55 minutes and recovered nothing more.
6. **List damaged files:** `ddru_ntfsfindbad sdXN.img sdXN.map` → `ntfsfindbad.log`.
7. **Extract:** `scripts/rescue/ntfs-extract.sh sdXN.img <dest> [extra-excludes]`
   (loop-mounts read-only, drops system files and caches). Delete the image only
   after rsync has finished.
8. **Lost file table** (mount fails: `Failed to load $Volume`): run
   `scrounge-ntfs -c 8 -o <dest> sdXN.img 0 <last sector>`. Without `-m` it
   searches the whole image for MFT records. Names survive; folders mostly do not.

## Outcome, pve3 HDD (2026-10-08)

| Partition | Imaged | Extracted (keep-set) | Damage in personal files |
| --- | --- | --- | --- |
| sda4 (D:, coursework, report cards) | 99.99 % of 35 GB used | 12 GB, 9,752 files | none: one Flutter `windows/runner` folder record |
| sda3 (C:, projects, AMIKOM) | 99.89 % of 141 GB used | 27 GB, 37,658 files | `Bene/raceto/sbd.PNG`, an installer zip, the folder `AMIKOM/SEMESTER 2/KOMUNIKASI DATA/tugas 9`, ≤256 unnamed files (lost `$MFT` records) |
| sda2 (projects, suitmedia) | 99.92 % of 212 GB (whole partition) | via scrounge-ntfs, flat names | the first ~117 MB of `$MFT` is unreadable: folder structure lost |

The disk itself: 8,448 pending sectors, not to be reused. Removed from pve3 on
2026-10-09 and kept offline; it still holds personal data, so destroy it physically
before disposal.

pve2's HDD stayed clean (9 reallocated, 0 pending, no errors) throughout. Its
keep-set, everything except Irene's 258 GB `Captures`, was copied to
`/mnt/staging/extract/pve2-hdd/`: 49 GB of C: user folders, 6.4 GB of E: (sda4),
96 GB of E: (sda5); 19,820 files. A dry-run `rsync` against the source listed 0
missing or different files. `Captures` is still a **single copy** on pve2's HDD
until the replacement disk arrives.

## One-off changes made (drift, to be removed)

- pve2: thin LV `pve/rescue-staging` mounted at `/mnt/staging` (not in fstab).
- pve2 HDD `sda4` (old Windows E:, contents copied to staging first) mounted
  read-write with `ntfs3 -o force` at `/mnt/e4`, overriding the Fast Startup dirty flag; it
  holds `_pve3-rescue/sda2.img` and a second copy of the extracted pve3 files
  (`_pve3-rescue/extract/`).
- Packages: pve2 `ntfs-3g gddrescue ddrutility scrounge-ntfs`;
  pve3 `gddrescue ddrutility sshfs ntfs-3g`.
- Re-encoding Irene's captures (2026-10-09): `ffmpeg vainfo intel-media-va-driver`
  on both nodes; pve3 sshfs mounts `/mnt/cap-src` (ro) and `/mnt/cap-out` from pve2;
  output on pve2 HDD `/mnt/e4/_captures-30fps`.

Cleanup when the archive is built: unmount, `lvremove pve/rescue-staging`, purge
the packages.
