# Runbook: SG108E from factory to the VLAN baseline

**When:** new or reset switch, or rebuilding after a hardware swap.
**Target:** TP-Link SG108E. Trunk cable from hEX `ether5` in **P8**; laptop in **P1**.
**Time:** ~15 minutes.

## Before

- Laptop set to static `192.168.0.2/24` to reach the switch's factory address.
- Do not move the P1 cable during the procedure — P1 stays on VLAN 1, so the
  management connection can never be lost.

## 1. Log in

`http://192.168.0.1` → `admin` / `admin`.

## 2. VLAN memberships — `VLAN → 802.1Q VLAN`

Edit **VLAN 1**: P1, P8 **Untagged**; P2–P7 **Not Member**.

Create (all unlisted ports = Not Member):

| VLAN | Tagged | Untagged |
| --- | --- | --- |
| 10 | P2, P3, P4, P8 | P5 |
| 20 | P2, P3, P4, P8 | — |
| 25 | P2, P3, P4, P8 | — |
| 30 | P2, P3, P4, P8 | — |
| 40 | P8 | P6, P7 |
| 50 | P8 | — |
| 60 | P2, P3, P4 | — |
| 999 | — | P2, P3, P4 |

## 3. PVIDs — `VLAN → 802.1Q PVID Setting`

| P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 999 | 999 | 999 | 10 | 40 | 40 | 1 |

## 4. Management IP — `System → System Info`

`192.168.99.2` / `255.255.255.248` / gateway `192.168.99.1`. The web page
will stop responding — expected, the switch has moved.

## 5. Laptop to the management subnet

Same screen where the static address was set: `192.168.99.3` /
`255.255.255.248`, router blank.

Verify:

- `http://192.168.99.2` loads
- `ping 192.168.99.1` answers (hEX, across the trunk)

## 6. Backup

`System → System Tools → Backup & Restore → Backup`, then commit the file to
`network/switch/backups/sg108e-<date>.cfg`.

## Notes

- Switch management is reachable directly from P1 (VLAN 1) and from the admin
  VLANs (10/40) through the hEX (`forward_switch_mgmt` rule).
- The port/VLAN plan lives in `docs/design/network-design.md` §3.
