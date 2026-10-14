# Runbook: node power operations

**Applies to:** the lab nodes (first written for `pve2`; pve1, the
on-demand desktop, in [Wake pve1](#wake-pve1)).

## Clean shutdown

- **Web UI:** select the node (`pve2`) → **Shutdown** (top-right).
- **Shell:** `shutdown -h now` — reboot is `reboot` (or `shutdown -r now`).
- **Physically:** press the power button **once, briefly**. The logind default
  is `HandlePowerKey=poweroff`, so it performs a clean shutdown.
- **Never** hold the power button or pull the plug (only for a frozen system).

What happens to guests: `pve-guests.service` runs `stopall` as the node goes
down, i.e. **all running guests are stopped** (gracefully, with their shutdown
timeouts — a busy guest can add up to a couple of minutes).

## Laptop specifics

- **Lid close does nothing** (`HandleLidSwitch=ignore`, sleep targets masked).
  It does not sleep and does not power off — by design for a server.
- **The batteries are NOT a UPS.** Both laptops report `BAT0` as present but
  "Not charging" with no readable capacity or charge data (checked 2026-10-08) —
  almost certainly dead. A power cut takes both nodes down hard, together with
  the hEX and switch. Until a real UPS is in place, treat every power dip as an
  unclean shutdown. (To confirm: a *supervised* unplug test with a console open.)
- For a full power-off: shut down first, wait for the screen to go dark, then
  unplug.
- **Power on:** press the power button. (No Wake-on-LAN for the laptops:
  they are always on.)

## Wake pve1

pve1 is off by design when not in use (ADR 0012) and wakes on a magic
packet: BIOS ErP off + Power On By PCI-E on, NIC armed at every boot
(Ansible `wake_on_lan`, `Wake-on: g`). Send it from another node, which sits
on VLAN 10 with it:

- **UI:** log in on pve2 or pve3 (`:8006`), select **pve1** (grey, offline) →
  **Wake-on-LAN** (top-right toolbar). The button is greyed out while pve1 is
  running. The node you are logged in to sends the packet, from its MGMT
  interface (`wakeonlan:` entries in the node configs, set by Ansible).
- **Shell** (`wakeonlan` is installed on every node by Ansible):

```bash
ssh root@10.10.10.13 wakeonlan -i 10.10.10.255 58:11:22:db:ea:e8   # or 10.10.10.12
ssh root@10.10.10.13 pvesh create /nodes/pve1/wakeonlan             # what the button calls
```

It answers SSH ~1 min later; the cluster goes from 2 to 3 votes. Shut it
down from the UI or `ssh root@10.10.10.11 poweroff` when done: it stops its
guests cleanly first. Monitoring sends one silent note while it is off
(`PveNodeDown`, info); everything else about pve1 and `ai` (ping, UI probe,
scrapes, the GPU exporter) is suppressed. Observed 2026-10-13 after a real
shutdown: exactly that, cluster quorate on 2 of 3 votes.

After a power cut it stays off unless it was running (BIOS: Restore AC Power
Loss = Last State). If a wake does nothing: it must have been shut down
cleanly at least once since the power came back (the NIC is armed by the OS),
and the switch port P2 must be up.

## Guests after a reboot

Only guests with `Start at boot = Yes` (guest → Options) start automatically.
`admin-gw` has it **on** → it returns by itself after a node boot; any guest
without it must be started manually.

## Before shutting down (optional checks)

- UI: the node summary lists running guests.
- Shell: `pct list` (containers), `qm list` (VMs).
