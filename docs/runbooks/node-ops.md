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
- The **battery is a built-in mini-UPS**; for a full power-off, shut down first,
  wait for the screen to go dark, then unplug.
- **Power on:** press the power button. (Wake-on-LAN for the laptops is not
  planned; it is planned for `pve1`.)

## Guests after a reboot

Only guests with `Start at boot = Yes` (guest → Options) start automatically.
`test-01` has it off → start it manually after a node boot.

## Before shutting down (optional checks)

- UI: the node summary lists running guests.
- Shell: `pct list` (containers), `qm list` (VMs).
