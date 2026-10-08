# Runbook: node power operations (pve2)

**Applies to:** the lab nodes (first written for `pve2`).

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
- **Power on:** press the power button. (Wake-on-LAN for the laptops is not
  planned; it is planned for `pve1`.)

## Guests after a reboot

Only guests with `Start at boot = Yes` (guest → Options) start automatically.
`admin-gw` has it **on** → it returns by itself after a node boot; any guest
without it must be started manually.

## Before shutting down (optional checks)

- UI: the node summary lists running guests.
- Shell: `pct list` (containers), `qm list` (VMs).
