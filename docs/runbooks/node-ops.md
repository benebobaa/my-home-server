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
  they are always on.) After a power cut they power on by themselves when
  the power returns, with the clock reset to an old date until chrony syncs
  (about 30 s; [2026-10-16](../incidents/2026-10-16-power-cut-pve1-stuck-off.md)).

## pve1 and the ai VM

pve1 is always on (ADR 0023). Wake-on-LAN stays armed (BIOS ErP off + Power On
By PCI-E on, NIC armed at every boot by Ansible `wake_on_lan`, `Wake-on: g`) as
the recovery path after a power cut. If it ever needs waking, send the packet
from another node, which sits on VLAN 10 with it:

- **UI:** log in on pve2 or pve3 (`:8006`), select **pve1** (grey, offline) →
  **Wake-on-LAN** (top-right toolbar). The button is greyed out while pve1 is
  running. The node you are logged in to sends the packet, from its MGMT
  interface (`wakeonlan:` entries in the node configs, set by Ansible).
- **Shell** (`wakeonlan` is installed on every node by Ansible):

```bash
ssh root@10.10.10.13 wakeonlan -i 10.10.10.255 58:11:22:db:ea:e8   # or 10.10.10.12
ssh root@10.10.10.13 pvesh create /nodes/pve1/wakeonlan             # what the button calls
```

Do not shut pve1 down for routine work. If it does need to be off, its guests
stop cleanly first (`poweroff` from the UI or `ssh root@10.10.10.11 poweroff`),
and the cluster drops to 2 of 3 votes. Monitoring treats pve1 as a standard
node: if it goes down, `PveNodeDown` is critical. The personal agent (`hermes`,
CT 141) starts with pve1 (`onboot`) and is online around the clock
([services/hermes](../../services/hermes/README.md)).

### The ai VM (on demand)

`ai` (VM 140) does not start with pve1 (`onboot 0`, ADR 0023). Start it when
learning AI, and shut it down cleanly when done:

```bash
ssh root@10.10.10.11 qm start 140       # or Start in the pve1 UI
ssh root@10.10.10.11 qm shutdown 140    # clean shutdown through the guest agent
```

While it runs it holds the RTX 3060 and 24 GB of pve1's memory, so the host
has about 8 GB for CT 141 and anything else.

After a power cut pve1 returns by itself only if the BIOS restores power on AC
loss (Restore AC Power Loss = Last State, with ErP off and Power On By PCI-E).
The OS cannot read these settings, so check them in the BIOS. If pve1 does
not come back:

1. Press pve1's power button. If it boots, the NIC was not armed: it is armed
   by the OS, so it needs one clean shutdown after a power cut. Also check
   that switch port P2 is up.
2. If the power button does nothing either (no lights, no fans), standby
   power is stuck, and neither Wake-on-LAN nor the BIOS restore can work.
   Switch the PSU off at its rear switch, wait 10 s, switch it on, then
   press the power button if it does not start by itself. This happened
   after the [2026-10-16 power cut](../incidents/2026-10-16-power-cut-pve1-stuck-off.md):
   pve1 was running when the power went and stayed dead for three days.

## Guests after a reboot

Only guests with `Start at boot = Yes` (guest → Options) start automatically.
`admin-gw` has it **on** → it returns by itself after a node boot; any guest
without it must be started manually.

## Before shutting down (optional checks)

- UI: the node summary lists running guests.
- Shell: `pct list` (containers), `qm list` (VMs).
