# Runbook: install Proxmox VE on a lab node (laptop)

**When:** bringing up a laptop node — first done for `pve2` (2026-10-06),
then `pve3` (2026-10-07).
**Time:** ~20 minutes + one cable move.

## Materials

- **Proxmox VE USB installer** — ISO `proxmox-ve_9.2-1.iso` (1.71 GB):
  <https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso> (torrent also
  offered on the download page). Write with `dd` (macOS/Linux) or Rufus in
  **DD mode** (Windows). Verify on macOS:
  `echo "4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c  proxmox-ve_9.2-1.iso" | shasum -a 256 -c`.
  Reusing a working stick from a previous node is fine.
- **USB Ethernet adapter** — Gigabit class (AX88179 / RTL8153 family). A
  100 Mb adapter works but bottlenecks migrations/backups; prefer Gigabit.
- **Ethernet cable** — reaches switch P5 for the install, then P3/P4.

## 0. Values

| Setting | pve2 | pve3 |
| --- | --- | --- |
| Hostname (FQDN) | `pve2.home.arpa` | `pve3.home.arpa` |
| Management IP (VLAN 10) | `10.10.10.12/24` | `10.10.10.13/24` |
| Gateway / DNS | `10.10.10.1` (the hEX) | same |
| Cluster IP (VLAN 60) | `10.10.60.12/24` | `10.10.60.13/24` |
| Switch port (final) | P3 — trunk: tagged 10/20/25/30/60, PVID 999 | P4 — same |
| Switch port (install) | P5 (untagged VLAN 10) — temporary | same |

## 1. BIOS

- Enable virtualization (Intel VT-x / AMD-V); optional VT-d / AMD IOMMU.
- Secure Boot: PVE 9 can boot with it; if the USB won't boot, disable it.
- Boot the USB installer (UEFI entry if offered; on Asus laptops tap **Esc**
  at power-on for the boot menu). If the USB isn't bootable at all, remake it
  with Rufus in **DD mode**.

## 2. Installer

- "Install Proxmox VE (Graphical)" — if the screen is garbled or there is no
  mouse, use the "Terminal UI" option instead (used for pve2/pve3).
- Target disk: internal drive, filesystem **ext4** (keep the default; do **not**
  pick ZFS on low-RAM laptops). This erases the disk.
- Location: Indonesia / Asia/Jakarta. Keyboard: U.S. English.
- Root password: a temporary one, shared with the operator for setup (rotate
  after SSH keys are installed). Email: any.
- Network step:
  - Management interface: the **USB Ethernet adapter** (`enx…`).
  - **Keep "Pin network interface names" enabled** (PVE 9 default): the adapter
    is renamed `nic0` on first boot, and every config in this repo assumes it.
  - Hostname / IP / gateway / DNS: the values table above.
- **Wire first:** have the USB NIC in switch **P5** so the fresh system comes
  up reachable at `10.10.10.12` (pve3: `10.10.10.13`).

## 3. Post-install (done over SSH from the workstation)

1. From a machine on VLAN 10/40: `ssh root@10.10.10.12` (pve3: `10.10.10.13`).
   (From the macOS workstation with Wi-Fi as primary, scope it:
   `ssh -o BindInterface=en8 root@10.10.10.12`.)
2. Install the admin machine's SSH key into `/root/.ssh/authorized_keys`.
3. Switch apt to the no-subscription repo; `apt update && apt full-upgrade`.
4. Laptop-as-server tweaks:
   - `/etc/systemd/logind.conf`: `HandleLidSwitch=ignore` (and
     `HandleLidSwitchExternalPower=ignore`);
   - `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
5. USB NIC hygiene:
   - `ethtool <usb-nic> | grep Speed` → must report **1000Mb/s** (a 100Mb
     adapter would bottleneck migrations/backups — replace it);
   - disable USB autosuspend (a known fix for USB NICs that randomly drop):
     add `usbcore.autosuspend=-1` to `GRUB_CMDLINE_LINUX_DEFAULT` in
     `/etc/default/grub`, then `update-grub`.
6. Replace `/etc/network/interfaces` with the template below (canonical copy:
   `proxmox/nodes/<node>/interfaces`), **without** reloading yet.
7. Move the USB NIC cable **P5 → P3** (pve2) or **P5 → P4** (pve3), then reboot
   the node.

## 4. Verify

- `ssh root@10.10.10.12` works again over the trunk (pve3: `10.10.10.13`).
- `ip -br a` shows `vmbr0.10` (10.10.10.12) and `vmbr0.60` (10.10.60.12)
  (pve3: `10.10.10.13` / `10.10.60.13`).
- `https://10.10.10.12:8006` loads from the workstation (pve3: `.13`).

## /etc/network/interfaces template

```text
auto lo
iface lo inet loopback

iface <usb-nic> inet manual

auto vmbr0
iface vmbr0 inet manual
    bridge-ports <usb-nic>
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 25 30 60

auto vmbr0.10
iface vmbr0.10 inet static
    address 10.10.10.12/24
    gateway 10.10.10.1

auto vmbr0.60
iface vmbr0.60 inet static
    address 10.10.60.12/24
```

Replace `<usb-nic>` with the adapter's real name (`ip -br link`) — with
installer pinning enabled that is `nic0`. Final per-node files live under
`proxmox/nodes/<node>/interfaces`.
