# Runbook: hEX reset + access bootstrap

**When:** first build, or whenever the router needs a clean slate.
**Target:** MikroTik hEX at `192.168.88.1`, laptop cabled to `ether3`.
**Time:** ~5 minutes.

## Before

- A config snapshot exists in `network/routeros/snapshots/`.
- Winbox is installed, and the `ether3` cable is attached to your machine.

## Steps

1. In Winbox, connect to `192.168.88.1` as `ben`, open a **Terminal** and run:

   ```routeros
   /system reset-configuration no-defaults=yes skip-backup=yes
   ```

   Confirm with `y`. The router reboots (~30 s).

2. Reconnect in Winbox **via MAC address** (discover/neighbours button; fallback
   MAC `08:55:31:34:7A:CB`). Log in as `admin` with an **empty password**.

3. Open `network/routeros/bootstrap.local.rsc`, copy everything, paste it into
   the Winbox terminal. Expected final line: `bootstrap complete`.
   If the session drops at the end, that's the `admin` user being disabled —
   reconnect as `ben`.

4. Verify (from the management Mac):

   ```sh
   ssh ben@192.168.88.1
   curl -k -u ben:<password> https://192.168.88.1/rest/system/identity
   ```

   Both must work; the REST call returns `{"name":"hex-lab"}`.

## What the bootstrap creates

Only the access layer — identity, `ben` user, OOB network on `ether3`
(`192.168.88.1/24` + DHCP pool), DNS forwarders, and the HTTPS REST API
(self-signed cert) that OpenTofu uses.

## Recovery

- Winbox **MAC access works regardless of IP/firewall config** as long as the
  `ether3` cable is attached — it is the way out of any router lockout.
- Totally bricked: physical reset button / netinstall (last resort).
