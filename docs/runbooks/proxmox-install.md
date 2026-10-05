# Runbook: install Proxmox VE on a lab node (laptop)

**When:** bringing up a laptop node — first done for `pve2` (2026-10-06).
**Needs:** Proxmox VE USB installer, USB Ethernet adapter, a free switch port
for the temporary install (P5 = untagged VLAN 10).
**Time:** ~20 minutes + one cable move.

## 0. Values

| Setting | Value |
| --- | --- |
| Hostname (FQDN) | `pve2.home.arpa` |
| Management IP | `10.10.10.12/24` (VLAN 10) |
| Gateway / DNS | `10.10.10.1` (the hEX) |
| Cluster IP | `10.10.60.12/24` (VLAN 60, future corosync) |
| Switch port (final) | P3 (trunk: tagged 10/20/25/30/60, PVID 999) |
| Switch port (install) | P5 (untagged VLAN 10) — temporary |

## 1. BIOS

- Enable virtualization (Intel VT-x / AMD-V); optional VT-d / AMD IOMMU.
- Secure Boot: PVE 9 can boot with it; if the USB won't boot, disable it.
- Boot the USB installer (UEFI entry if offered). If the USB isn't bootable at
  all, remake it with Rufus in **DD mode**.

## 2. Installer

- "Install Proxmox VE (Graphical)" — if the screen is garbled, use the
  "Terminal UI" option instead.
- Target disk: internal drive, filesystem **ext4** (keep the default; do **not**
  pick ZFS on low-RAM laptops). This erases the disk.
- Location: Indonesia / Asia/Jakarta. Keyboard: U.S. English.
- Root password: a temporary one, shared with the operator for setup (rotate
  after SSH keys are installed). Email: any.
- Network step:
  - Management interface: the **USB Ethernet adapter** (`enx…`).
  - Hostname / IP / gateway / DNS: the values table above.
- **Wire first:** have the USB NIC in switch **P5** so the fresh system comes
  up reachable at `10.10.10.12`.

## 3. Post-install (done over SSH from the workstation)

1. From a machine on VLAN 10/40: `ssh root@10.10.10.12`.
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
6. Replace `/etc/network/interfaces` with the template below, **without**
   reloading yet.
7. Move the USB NIC cable **P5 → P3**, then reboot the node.

## 4. Verify

- `ssh root@10.10.10.12` works again over the trunk.
- `ip -br a` shows `vmbr0.10` (10.10.10.12) and `vmbr0.60` (10.10.60.12).
- `https://10.10.10.12:8006` loads from the workstation.

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

Replace `<usb-nic>` with the adapter's real name (`ip -br link`). The final
file is stored under `proxmox/nodes/pve2/interfaces` once built.
