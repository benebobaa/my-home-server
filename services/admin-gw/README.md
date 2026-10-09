# admin-gw — Tailscale subnet routers (HA pair)

Makes the whole lab reachable for management **from anywhere**, with zero
inbound ports at home. Tailscale traffic is end-to-end encrypted; the
household router and any VPS never see it. Design:
`docs/design/network-design.md` § Remote admin.

**Live since 2026-10-07** — verified cable-free management from the operator
Mac over Wi-Fi. The path relays via Tailscale DERP (Singapore, ~52 ms)
because both ends sit behind CGNAT — that is by design (zero inbound).

## What it is

| | |
| --- | --- |
| Hosts | `admin-gw`: CT `101` on `pve3`, `10.10.10.15` · `admin-gw2`: CT `102` on `pve2`, `10.10.10.17` (each unprivileged, 1 core, 512 MB RAM, 3 GB disk) |
| Network | VLAN 10 (MGMT), static IPs from `inventory/lab.yaml`, gw `10.10.10.1` |
| HA | Both advertise the same routes. Clients use one (the primary) and Tailscale moves them to the other when it goes offline. Measured 2026-10-09: about a 55–75 s gap, then the other gateway serves at the same latency. The primary is sticky: it stays where it failed over to. Since 2026-10-09 ([RCA](../../docs/incidents/2026-10-09-remote-access-degraded.md)) |
| Device | `/dev/net/tun` passed through (Tailscale needs it) |
| Boot | `onboot` — comes back automatically with the node |
| Routes | advertises `10.10.10.0/24` (nodes + hEX), `192.168.99.0/29` (switch + recovery) |

The hEX firewall trusts both IPs (address-list `admin-gw`) for management
access to the router, the switch UI and all lab VLANs.

## Access cheat-sheet (over Tailscale, from anywhere)

| What | Address | Notes |
| --- | --- | --- |
| Proxmox (cluster) | `https://10.10.10.13:8006` (or `.12`) | accept the self-signed cert; either node shows the whole Datacenter |
| Proxmox SSH | `ssh root@10.10.10.12` / `.13` | key-based |
| hEX WinBox | `10.10.10.1` (port 8291) | "Connect To" field |
| hEX WebFig / SSH | `https://10.10.10.1` · `ssh ben@10.10.10.1` | |
| Switch (SG108E) UI | `http://192.168.99.2` | tiny web server — the first hit can be slow, retry |
| admin-gw itself | `ssh root@10.10.10.15` (or `100.64.185.120`) | |

Any device with Tailscale (same account) gets these routes automatically.
Fallbacks if both gateways are down: P7 cable (direct) or the P1 recovery
port (hEX + switch only).

## Provisioning (all from this repo)

1. **Container + Tailscale install:** `proxmox/opentofu/` (OpenTofu) creates
   the container, runs `provision.sh` (installs Tailscale, enables IP
   forwarding via `/etc/sysctl.d`), and applies the `/dev/net/tun`
   passthrough over SSH (PVE restricts `dev*` config to root sessions; the
   API token cannot). Do **not** hand-edit the container — change the HCL
   and `tofu apply`.
2. **One-time interactive steps** (Tailscale account level):
   - Inside the CT (`--hostname` = the CT's name, `admin-gw` or `admin-gw2`):
     ```
     tailscale up --hostname=admin-gw2 --accept-dns=false \
       --advertise-routes=10.10.10.0/24,192.168.99.0/29
     ```
     → open the printed URL, sign in with the Tailscale account.
   - Tailscale admin console → Machines → the gateway:
     - **approve** both subnet routes,
     - **disable key expiry** (the gateway must never fall off the tailnet).
3. **Client side:** Tailscale on your devices (Mac app already installed;
   phone optional). Approved routes are used automatically.
   Test: unplug the Ethernet cable — `https://10.10.10.13:8006` still opens.

## Operations

- Status: `tailscale status`, `tailscale ip -4` (shows the 100.x address).
- Updates: Tailscale auto-update is on (`tailscale set --auto-update`, in
  `provision.sh`; check with `tailscale debug prefs | grep -A3 AutoUpdate`).
- Logs: `journalctl -u tailscaled -e`.
- Changed routes? Re-run `tailscale up` with the new `--advertise-routes`
  and re-approve in the console.
- `tailscale up` complaining about the TUN device? Check the passthrough:
  `pct config 101 | grep dev0`.
- Root-only container config (`dev0`) is owned by the OpenTofu step
  `terraform_data.admin_gw_tun["<name>"]`; after editing
  `proxmox/opentofu/files/admin-gw-root-config.sh`, re-run one gateway at a
  time with `tofu apply -replace='terraform_data.admin_gw_tun["admin-gw2"]'`.
- Stuck UIs while the gateway is "online": see the recovery steps in the
  [RCA](../../docs/incidents/2026-10-09-remote-access-degraded.md#recovery-procedure-until-action-2-lands-in-a-runbook).
- `provision.sh` re-runs on **both** gateways at the next `tofu apply` after
  it is edited (its hash is a trigger). It is idempotent and does not restart
  tailscaled; to be careful, apply one at a time with
  `-target='terraform_data.admin_gw_setup["admin-gw2"]'` first.

## Security notes

- Tailnet default ACL allows all your own devices — tighten later if the
  tailnet grows (design § Remote admin).
- This CT is the single management door; it runs exactly one service, on
  MGMT VLAN 10, unprivileged.
- No single point of failure for remote access: one gateway per node. A
  gateway whose tailscaled is *degraded but online* does not trigger
  failover (Tailscale fails over on offline, not on slow). Fix: restart its
  tailscaled; the other gateway carries traffic meanwhile.
- Change, restart or rebuild **one gateway at a time**, and confirm the other
  is serving (`tailscale status` on the Mac) first.
