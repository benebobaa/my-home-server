# admin-gw — Tailscale subnet router

Makes the whole lab reachable for management **from anywhere**, with zero
inbound ports at home. Tailscale traffic is end-to-end encrypted; the
household router and any VPS never see it. Design:
`docs/design/network-design.md` § Remote admin.

## What it is

| | |
| --- | --- |
| Host | CT `101` on `pve3` (unprivileged, 1 core, 512 MB RAM, 3 GB disk) |
| Network | VLAN 10 (MGMT), static `10.10.10.15/24`, gw `10.10.10.1` |
| Device | `/dev/net/tun` passed through (Tailscale needs it) |
| Boot | `onboot` — comes back automatically with the node |
| Routes | advertises `10.10.10.0/24` (nodes + hEX), `192.168.99.0/29` (switch + recovery) |

The hEX firewall already trusts `10.10.10.15` (address-list `admin-gw`) for
management access to the router, the switch UI and all lab VLANs.

## Provisioning (all from this repo)

1. **Container + Tailscale install:** `proxmox/opentofu/` (OpenTofu) creates
   the container, runs `provision.sh` (installs Tailscale, enables IP
   forwarding via `/etc/sysctl.d`), and applies the `/dev/net/tun`
   passthrough over SSH (PVE restricts `dev*` config to root sessions; the
   API token cannot). Do **not** hand-edit the container — change the HCL
   and `tofu apply`.
2. **One-time interactive steps** (Tailscale account level):
   - Inside the CT:
     ```
     tailscale up --hostname=admin-gw --accept-dns=false \
       --advertise-routes=10.10.10.0/24,192.168.99.0/29
     ```
     → open the printed URL, sign in with the Tailscale account.
   - Tailscale admin console → Machines → `admin-gw`:
     - **approve** both subnet routes,
     - **disable key expiry** (the gateway must never fall off the tailnet).
3. **Client side:** Tailscale on your devices (Mac app already installed;
   phone optional). Approved routes are used automatically.
   Test: unplug the Ethernet cable — `https://10.10.10.13:8006` still opens.

## Operations

- Status: `tailscale status`, `tailscale ip -4` (shows the 100.x address).
- Logs: `journalctl -u tailscaled -e`.
- Changed routes? Re-run `tailscale up` with the new `--advertise-routes`
  and re-approve in the console.
- `tailscale up` complaining about the TUN device? Check the passthrough:
  `pct config 101 | grep dev0`.
- Root-only container config (`dev0`) is owned by the OpenTofu step
  `terraform_data.admin_gw_tun`; after editing
  `proxmox/opentofu/files/admin-gw-root-config.sh`, re-run with
  `tofu apply -replace=terraform_data.admin_gw_tun`.
- `provision.sh` runs only at container creation; after editing it, apply by
  hand (`scp` it in and run it) or recreate the container.

## Security notes

- Tailnet default ACL allows all your own devices — tighten later if the
  tailnet grows (design § Remote admin).
- This CT is the single management door; it runs exactly one service, on
  MGMT VLAN 10, unprivileged.
- Single point of failure for remote access: if `pve3` is down, reach the
  lab over the cable (P7) or the P1 recovery port. Planned mitigation: a
  second subnet router on `pve2` with the same routes (Tailscale fails over
  automatically between routers).
