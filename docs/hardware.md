# Hardware

What the lab physically is: models, parts, serials and health. Addresses,
VMIDs and placement are not here; they live in
[`inventory/lab.yaml`](../inventory/lab.yaml).

**Read from the devices on 2026-10-09** (DMI, `lscpu`, `dmidecode`,
`smartctl`, `lspci`, RouterOS `/system`). Health values are a snapshot of
that day; live values are in Grafana. The repo is public, so serials and
MACs are shortened to their last digits. Update this file when a part changes
(see [Refreshing](#refreshing)).

## Summary

| Identity | Hardware | CPU | RAM | Storage | Network |
| --- | --- | --- | --- | --- | --- |
| `pve1` | Desktop (planned, not built) | Ryzen 5 5600 | 32 GB | not recorded | not recorded |
| `pve2` | ASUS VivoBook 14 X407UF | i3-7020U, 2C/4T | 12 GB DDR4 | 480 GB SSD + 1 TB HDD | USB GbE |
| `pve3` | ASUS VivoBook 14 X407UF | i3-7020U, 2C/4T | 8 GB DDR4 | 128 GB SSD | USB GbE |
| `hex` | MikroTik hEX RB750Gr3 r4 | MT7621, 880 MHz | 256 MB | 16 MB flash | 5× GbE |
| `switch` | TP-Link TL-SG108E | — | — | — | 8× GbE |
| operator Mac | MacBook Air M1 (MacBookAir10,1) | Apple M1, 4P+4E | 8 GB | — | Wi-Fi |

## pve2 — ASUS VivoBook 14 X407UF (stateful node)

| Part | Detail |
| --- | --- |
| System | ASUSTeK VivoBook 14_ASUS Laptop X407UF, serial `…12944G` |
| Firmware | BIOS X407UF.304 (2019-06-05), UEFI 64-bit, Secure Boot **off** |
| CPU | Intel Core i3-7020U (Kaby Lake, 15 W): 2 cores / 4 threads, 2.3 GHz fixed (no turbo), 3 MB L3, VT-x, microcode `0xf6` |
| RAM | 12 GB DDR4 at 2133 MT/s (the CPU's maximum): ChannelA 4 GB Samsung `M471A5244CB0-CRC` + ChannelB 8 GB Kingston `9905700-097.A00G` |
| iGPU | Intel HD Graphics 620 (`8086:5921`), used for VAAPI encoding |
| dGPU | NVIDIA GeForce MX130 (GM108M, `10de:174d`), 2 GB GDDR5, PCIe 3.0 x4, VBIOS `82.08.72.00.93`, driver 580.178.04 ([ADR 0003](decisions/0003-lxc-gpu-passthrough.md), [experiment](experiments/mx130/README.md)) |
| SSD (`sdb`, boot) | Kingston A400 `SA400M8480G`, 480 GB SATA M.2, serial `…19DC75`, fw `SBFK62B3` |
| HDD (`sda`) | Toshiba `MQ04ABF100`, 1 TB 2.5" 5400 rpm SATA, serial `…MW3CFT`, fw `JU0C0J` |
| NIC | ASIX AX88179 USB 3.0 gigabit (`0b95:1790`, `cdc_ncm` driver), on a 5 Gb/s port, 1000 Mb/s link, MAC `…:f0:18` (`nic0`) |
| Display out | HDMI (`card1-HDMI-A-1`) |
| Wi-Fi | no wireless interface present |
| Battery | `BAT0` exists but reports no capacity and "Not charging". It does **not** keep the node up through a power loss (2026-10-09) |
| OS | Proxmox VE 9.2.21, kernel 7.0.14-22-pve |

SSD layout (VG `pve`, 446 GB, 16 GB free): root 96 GB, swap 8 GB, thin pool
`data` 320 GB. The thin pool holds `rescue-staging` 290 GB (the archive's
second copy, [disk-rescue](runbooks/disk-rescue.md)), CT 120 12 GB and
CT 110 4 GB. It was **70 % used** on 2026-10-09; the SSD is pve2's tightest
resource.

HDD layout: old Windows partitions (NTFS `sda3` 200 GB, `sda4` and `sda5`
365 GB each), with `sda4` mounted read-only at `/mnt/e4` for the archive. It is
planned to become a ZFS pool (README → Status).

Health on 2026-10-09:

| Disk | SMART | Power-on | Wear / errors |
| --- | --- | --- | --- |
| Kingston SSD | PASSED | 8,470 h, 2,559 cycles | **95 % life left**, 22 TiB host writes / 25 TiB flash writes, 0 uncorrectable, 530 unsafe shutdowns |
| Toshiba HDD | PASSED | 6,348 h, 4,739 cycles | 9 reallocated, 0 pending, 0 offline-uncorrectable, 0 CRC; 220k load cycles |

## pve3 — ASUS VivoBook 14 X407UF (stateless node)

| Part | Detail |
| --- | --- |
| System | Same model as pve2, serial `…739514` |
| Firmware | BIOS X407UF.**306** (2019-08-08, newer than pve2's), UEFI 64-bit, Secure Boot **off** |
| CPU | Intel Core i3-7020U, same as pve2 (microcode `0xf6`) |
| RAM | 8 GB DDR4 at 2133 MT/s: ChannelA 4 GB Samsung `M471A5244CB0-CWE` + ChannelB 4 GB SK Hynix `HMA851S6AFR6N-UH` |
| iGPU / dGPU | HD Graphics 620 / GeForce MX130, 2 GB (same IDs, VBIOS and driver as pve2) |
| SSD (`sda`, boot) | No-name "M.2 128GB", 128 GB SATA, serial `…548408`, fw `HP3C09BA`. Installed 2026-10 (44 power-on hours) |
| HDD | none. The Toshiba 1 TB (serial `…X8PEW8QJT`) failed and was removed ([disk-rescue](runbooks/disk-rescue.md)); the 2.5" bay is empty |
| NIC | ASIX AX88179 USB 3.0 gigabit, 1000 Mb/s link, MAC `…:d0:71` (`nic0`) |
| Wi-Fi / battery | same as pve2: no Wi-Fi interface; the battery does not hold the node up |
| OS | Proxmox VE 9.2.21, kernel 7.0.14-22-pve |

SSD layout (VG `pve`, 118 GB, 15 GB free): root 40 GB, swap 7.6 GB, thin pool
`data` 54 GB at 2 % (CT 101, 3 GB).

Health on 2026-10-09: SMART PASSED, 44 h, 0 reallocated / pending /
uncorrectable, 40 °C. Its vendor attributes don't add up: 400
`Erase_Fail_Count_Chip` and a `Wear_Leveling_Count` raw value of 126,588 after
44 hours. Don't trust its SMART numbers, and keep the placement rule
(stateless or rebuildable guests only, AGENTS.md).

## pve1 — desktop (planned)

Recorded so far: AMD Ryzen 5 5600 (6 cores / 12 threads), 32 GB RAM,
NVIDIA RTX 3060. Board, disks, NIC and PSU are not recorded yet; fill them in
from the box when it's built. It runs on demand, not always-on.

## hex — MikroTik hEX RB750Gr3

| Part | Detail |
| --- | --- |
| Board | RB750Gr3 revision r4, serial `…FD49E2` |
| CPU | MediaTek MT7621 (MIPS 1004Kc), 2 cores / 4 threads, 880 MHz |
| RAM / flash | 256 MB / 16 MB (3.6 MB free) |
| Software | RouterOS 7.23.7 long-term, RouterBOOT 7.23.7 (factory: RouterOS 6.46.3, firmware 6.47.4) |
| Health | 11.9 V input, 42 °C |
| Ports | ether1–5 GbE, MACs `…:7A:C9` … `…:7A:CD` |

Port roles are in the [network design](design/network-design.md) (ether1 WAN,
ether3 OOB, ether5 trunk to switch P8).

On 2026-10-09, **ether1 (WAN) linked at 100 Mb/s full duplex**, because the
Biznet router's port advertises nothing above 100M. ether5 linked at 1 Gb/s.
The lab's internet throughput is therefore capped at 100 Mb/s. Likely causes
are a Fast Ethernet LAN port on the Biznet unit or a 4-wire/damaged cable;
another Biznet LAN port or a new Cat5e/Cat6 cable would show which.

## switch — TP-Link TL-SG108E

8-port gigabit, 802.1Q VLANs, managed only through its web UI
([`network/switch/`](../network/switch/)). Its hardware and firmware versions
are not recorded yet: the hardware version is on the label underneath ("Ver
X.0"), and the firmware is under System → System Info in the UI.

## Upstream — Biznet router

ISP-owned unit, not changed by us (design §1). Model not recorded. Its LAN
port to the hEX runs at 100 Mb/s (see hex above).

## Operator Mac

MacBook Air M1 (MacBookAir10,1), 8 cores (4P + 4E), 8 GB. It holds the age
key ([secrets runbook](runbooks/secrets.md)) and reaches the lab over
Tailscale through `admin-gw`.

## Limits and upgrade notes

- **No UPS.** The laptop batteries don't hold the nodes up: pve2, pve3 and the
  hEX all rebooted together at ~16:20 WIB on 2026-10-09, consistent with a
  power cut. A UPS is on the
  foundation list (README → Status).
- **Laptop RAM.** Each X407UF reports two populated channels (A and B). The
  Samsung module on ChannelA is most likely the soldered on-board 4 GB, which
  would leave one SODIMM slot (ChannelB), for a likely maximum of 4 + 16 =
  20 GB. Check the slot before buying. pve3 (8 GB) gains the most. Memory
  runs at 2133 MT/s whatever the module speed.
- **Storage.** pve2's SSD thin pool is the tight spot (70 %, mostly
  `rescue-staging`). pve3 has an empty 2.5" SATA bay.
- **The i3-7020U has no turbo.** CPU-heavy work belongs to pve1.

## Refreshing

Read-only commands that produced this file (run on each node as root):

```bash
cat /sys/class/dmi/id/{sys_vendor,product_name,product_serial,bios_version,bios_date}
lscpu; free -h; dmidecode -t 17
lsblk -o NAME,SIZE,TYPE,ROTA,TRAN,FSTYPE,MOUNTPOINT,MODEL
smartctl -i -H -A /dev/sdX
lspci -nn; lsusb; ethtool -i nic0; cat /sys/class/net/nic0/speed
nvidia-smi --query-gpu=name,memory.total,driver_version,vbios_version --format=csv
```

On the hEX: `/system resource print`, `/system routerboard print`,
`/system health print`, `/interface ethernet monitor [find] once`.
