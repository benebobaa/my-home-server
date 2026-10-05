# hEX — MikroTik RB750Gr3 (RouterOS 7)

## Port plan (as cabled)

| Port | Role |
| --- | --- |
| ether1 | WAN — uplink to the Biznet router (DHCP client) |
| ether2 | spare |
| ether3 | OOB management — direct laptop / recovery (192.168.88.1/24) |
| ether4 | spare |
| ether5 | trunk to switch port P8 (VLANs 10, 20, 25, 30, 40, 50 tagged + VLAN 1 native) |

## Factory reset (start from zero)

1. In Winbox, open a Terminal and run:

   `/system reset-configuration no-defaults=yes skip-backup=yes`

   Confirm with `y`; the router reboots (~30 s).
2. Reconnect **via MAC address** (Winbox neighbours). Log in as `admin` with an
   empty password.
3. Paste `bootstrap.local.rsc`. If Winbox drops on the last line (the admin user
   gets disabled), reconnect as `ben`.
4. Verify from the Mac:

   `ssh ben@192.168.88.1` and
   `curl -k -u ben:<password> https://192.168.88.1/rest/system/identity`

The bootstrap creates only: identity, admin user, OOB network on ether3, DNS
forwarders, and the HTTPS REST API (self-signed) that OpenTofu talks to.

## OpenTofu workflow

```sh
cd routeros
set -a; source .env; set +a    # ROS_USERNAME / ROS_PASSWORD
tofu init
tofu plan                      # review
tofu apply                     # commit to the device
```

Provider: `terraform-routeros/routeros` over REST (`https://192.168.88.1`,
self-signed → `insecure = true`). State stays local (`terraform.tfstate`, ignored).

## Snapshots

```sh
ssh ben@192.168.88.1 '/export' > snapshots/hex-$(date +%F-%H%M).rsc
```
