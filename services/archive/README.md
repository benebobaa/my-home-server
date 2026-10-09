# archive — family files, read-only, over Tailscale

File Browser in CT 110 on pve2 (`10.10.20.30`, VLAN 20). Bene and Irene
browse, preview and download the family archive from any device with the
Tailscale app. It is never public. Why not Cloudflare Tunnel:
[ADR 0005](../../docs/decisions/0005-family-archive-over-tailscale.md).

| | |
| --- | --- |
| URL | `https://archive.tailbc7ce3.ts.net` (`tailscale serve` → `127.0.0.1:8080`; node `archive`, 100.93.77.50) |
| Users | `bene`, `irene`: download/preview only (no create/rename/modify/delete/share/exec) |
| Passwords | `proxmox/opentofu/secrets.sops.env`. Read Irene's with `sops -d --extract '["TF_VAR_archive_irene_password"]' proxmox/opentofu/secrets.sops.env` |
| Data | `/srv/archive` (mp0, `ro=1`) + `/srv/archive/irene/zoom-recordings` (mp1, `ro=1`) |
| Built by | `proxmox/opentofu/archive.tf` → `provision.sh` (in guest) + `files/archive-root-config.sh` (host, root) |

## Archive layout (interim, 2026-10-09)

The archive's **source of truth is still the original disk (pve2 HDD)**;
this tree is the verified second copy on pve2's SSD (thin LV
`pve/rescue-staging`, `/mnt/staging/archive`). Built with `mv` from the
extracted trees (68,804 files before and after):

| Archive path | From |
| --- | --- |
| `irene/14 IRENE PURI KUMALA` | E: (`sda5`) `14 IRENE PURI KUMALA`, minus `Captures` |
| `irene/14 IRENE PURI KUMALA (laptop Documents copy)` | C: `Users/ASUS/Documents/14 IRENE PURI KUMALA` (likely duplicate, dedupe later) |
| `irene/A LESSON IRENE MUSIC` | E: (`sda4`) |
| `irene/zoom-recordings` | mp1 → pve2 HDD `/mnt/e4/_captures-30fps`: `Captures` re-encoded (below) |
| `bene/old-laptop C-drive`, `bene/old-laptop D-drive` | failed pve3 HDD `sda3` / `sda4`, rescued ([disk-rescue](../../docs/runbooks/disk-rescue.md)) |
| `bene/BenediktusMUKTI`, `bene/asus-laptop bene` | E: `sda5` / `sda4` |
| `clara/*` | C: Documents (MATERI D3 CLARA, MATERI CLARA P, AKREDITASI 2018/2020, SPO TB PDF, MATERI SEMINAR TB DAY 2019); E: `sda4` (RPL 2021, BAHAN PPS TB, LOGBOOK, 11.SERTIFIKAT, LAMPIRAN/TOR/PP PN docs, HEALING GARDEN); OneDrive RPL 2021 copy |
| `family/asus-laptop user files` | the rest of C: `Users/ASUS` (Pictures, Videos, Music, Downloads, Desktop, …) |
| `family/asus-laptop public files`, `family/asus-laptop E-drive (rest)`, `family/asus-laptop E5-drive (rest)` | remaining C: `Users/Public`, E: `sda4`, E: `sda5` |

Not yet in the tree: the files scrounged from the failed disk's `sda2`
(`/mnt/staging/extract/pve3-hdd/C2-sda2-scrounged`, ~172k files, mostly
flattened). 58 dangling Windows junctions (`My Music` etc.) were removed.

### Zoom recordings

`Captures` (288 files, 120 h, 1376×776 @ 60 fps, 276 GB) re-encoded on both
nodes' Intel iGPUs (VAAPI H.264, 30 fps, CQP 27, audio copied):
**~12 % of the original size, SSIM 0.990** on a test clip, ~16× real time
per node. Worker: `scripts/rescue/encode-worker.sh`. The originals stay on the
pve2 HDD until Irene has checked some re-encodes.

## Operator steps (account-level, once)

Steps 1–4 done 2026-10-09 (key expiry disabled, HTTPS on, serve active). Verified
from the operator Mac over Tailscale: login 200, wrong password 403, DELETE 403,
a downloaded PDF's sha256 matches the source, video range requests return 206.

1. **Log the node in:** run `tailscale up --hostname=archive --accept-dns=false` in the CT
   and open the printed URL.
2. In the Tailscale admin console → Machines → `archive`: **Disable key expiry**.
3. DNS page: **MagicDNS** and **HTTPS Certificates** on (needed by
   `tailscale serve --https=443`).
4. In the CT: `tailscale serve --bg --https=443 http://127.0.0.1:8080`.
5. Machines → `archive` → **Share…** → send the invite link to Irene. She
   installs the Tailscale app, signs in with her own account, accepts. She
   sees only this machine, not the lab.
6. Give Irene her password out of band.

The tailnet ACL is the default allow-all (see `services/admin-gw/README.md`).
If it is tightened, keep shared users → `archive:443` allowed.

## Not boot-safe yet

`start_on_boot = false`: `/mnt/staging` and `/mnt/e4` are mounted by hand
(rescue leftovers, not in fstab). This goes away when the archive moves to a
ZFS pool on the HDD. After a pve2 reboot (done this way 2026-10-09):

```sh
ssh root@10.10.10.12
mount -o discard /dev/pve/rescue-staging /mnt/staging
mount -t ntfs3 -o ro UUID=285A98915A985D7E /mnt/e4   # pve2 HDD sda4, read-only
pct start 110
```

`/mnt/e4` is read-only now: the re-encodes are finished, and it holds the only
copy of the original `Captures`. Remount it `rw,force` only for a deliberate
write. Check: the archive URL loads, `irene/zoom-recordings` lists 288 files,
and the `HostUnreachable` alert for `archive` resolves.

## Maintenance

File Browser's database is BoltDB, which takes an exclusive lock:
`systemctl stop filebrowser` before using the CLI
(`runuser -u filebrowser -- /usr/local/bin/filebrowser -d /var/lib/filebrowser/filebrowser.db users ls`).

If VLAN 20 egress is ever tightened on the hEX, keep UDP 41641 and TCP 443
outbound for this CT (Tailscale direct and DERP).
