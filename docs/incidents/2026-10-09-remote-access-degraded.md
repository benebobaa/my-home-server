# 2026-10-09: remote access degraded after the lab power-cycle

| | |
| --- | --- |
| **Status** | Resolved 2026-10-09 18:20 WIB |
| **Impact** | The operator's Proxmox UIs (pve2, pve3), Grafana and SSH "loaded endlessly" from the Mac. Every service in the lab stayed up the whole time; only the remote-access path was broken. |
| **Duration** | Earliest evidence 17:39, reported about 17:57, resolved 18:20 (about 40 min). It may have started at boot (16:21) and gone unnoticed. |
| **Trigger** | The planned whole-lab power-off at 16:00 (operator), back at about 16:20 |
| **Root cause** | The Tailscale daemon on `admin-gw` (CT 101, pve3) came out of the power-cycle with a degraded relay session. Full analysis below; the exact internal fault inside tailscaled is unknown. |
| **Fix** | `systemctl restart tailscaled` on `admin-gw` |

## Summary

The operator reaches the lab only through Tailscale, via the subnet router
`admin-gw` (design §6). The Mac sat on the Biznet household Wi-Fi, behind the
same CGNAT as the lab. Both ends report `MappingVariesByDestIP: true`, so
there is never a direct connection, and all traffic is relayed through
Tailscale's DERP server in Singapore. That is the normal state, and it works
fine: about 53 ms and steady.

After the power-cycle, `admin-gw`'s session through that relay went bad, with
55–100% packet loss and round trips up to 10 s. At the same moment, another
lab peer (`archive`, CT 110) answered over the same relay at 53 ms. Prometheus
showed every target up, because monitoring sits inside the lab and never
uses this path.

## Timeline (WIB)

| Time | Event |
| --- | --- |
| 16:00:41 / 16:00:45 | The operator shuts down pve2 and pve3 cleanly, then powers the whole lab off, hEX included. |
| ~16:20 | Power back. `admin-gw` boots at 16:21; tailscaled is the same version as before (1.102.5). |
| 17:39–17:41 | `admin-gw` logs `magicsock: derp-3 does not know about peer [dZnCe], removing route` every 5 s. This is the earliest evidence. |
| ~17:57 | The operator reports that the Grafana and Proxmox UIs load endlessly. |
| 17:58 | Every lab IP shows 100% loss from the Mac. `tailscale ping admin-gw`: the first pong arrives via DERP after 4.6 s. |
| 18:00 | Ping to `admin-gw`'s tailnet IP: 55% loss, 10.2 s average. The Mac's own internet is clean (1.1.1.1 at 19 ms, 0% loss). |
| 18:01 | From `admin-gw`: 1.1.1.1 at 18 ms, 0% loss. The lab's uplink is healthy. |
| 18:03 | `tailscale debug rebind` + `restun` on both ends. Loss drops to 0%, but the average is 250 ms with spikes to 1.1 s; the UIs answer in 0.7–4 s. |
| 18:09 | Relapse: 100% loss to `admin-gw` and the UIs time out, while `archive` answers at 60 ms. |
| 18:10–18:17 | Narrowing down (see [Analysis](#analysis)). In parallel pings, `archive` gets 53 ± 0.7 ms and `admin-gw` 258 ± 244 ms. |
| 18:19 | Fallback armed on pve3 (`pct reboot 101` in 240 s), then tailscaled restarted on `admin-gw`. |
| 18:20 | UIs answer in 0.18–0.27 s. In parallel pings, `admin-gw` gets 56 ± 2.9 ms, `archive` 54 ms and pve2 60 ms, all with 0% loss. Fallback cancelled. |

## Analysis

What the comparisons ruled out. The decisive test was pinging `admin-gw` and
`archive` from the same Mac, over the same relay, at the same time.

| Suspect | Evidence | Verdict |
| --- | --- | --- |
| Mac Wi-Fi or Biznet uplink | Mac → 1.1.1.1 at 19 ms with 0% loss; Mac → `archive` (same uplink) at 53 ms | Ruled out |
| DERP relay "sin" | `archive` at 53 ms through the same relay at the same time | Ruled out |
| Lab uplink or hEX | `admin-gw` → 1.1.1.1 at 18 ms with 0% loss; `admin-gw` → hEX at 2 ms; `archive` sits behind the same hEX | Ruled out |
| hEX queue | The only queue (`dmz-internet`) targets VLAN 25; `admin-gw` is on VLAN 10 | Ruled out |
| pve3 NIC | pve3 and pve2 have the same adapter (AX88179B, `cdc_ncm`, 1000 Mb/s); 0 errors, 0 qdisc drops; the counters look alike | Ruled out |
| `admin-gw`'s DERP TCP link | 40 ms round trip, nothing queued at the time of measurement | Not the fault at the TCP level |
| Tailscale upgrade at boot | 1.102.5 in both the previous and the current boot; last apt install was 2026-10-07 | Ruled out |
| tailscaled state inside `admin-gw` | Partly cleared by a rebind, relapsed within about 6 min, fully fixed by a restart, and stable since | **Cause** |

The `derp-3 does not know about peer` messages point to stale relay routing
inside `admin-gw`'s tailscaled after the reboot. The relay server had dropped
the Mac's session, but the gateway kept sending to it for a while. A restart
rebuilds all peer and relay state from scratch. Why the stale state persisted
after the boot, rather than clearing by itself, is not known.

One test result was misleading. From inside the lab, `archive` → `admin-gw`
also timed out. But `archive`'s Tailscale had chosen a "direct" path to
`10.10.10.15:41641`, and the hEX drops SERVERS → MGMT traffic (design §4). That
timeout reflects the firewall, not the fault, so it was not used as evidence.

Not causal, but noted: in the unprivileged CT, tailscaled logs `failed to
force-set UDP read/write buffer size ... operation not permitted`. That
limits throughput only.

## What went well

- The lab itself was fine throughout, and so was the monitoring of it.
- Comparing two peers in parallel (`admin-gw` against `archive`) separated
  shared causes from local ones in a single 30 s test.
- The restart was done with a fallback armed (`systemd-run ... pct reboot
  101` on pve3), so losing the only access path would have recovered by
  itself.

## What went wrong

- **A single point of failure.** `admin-gw` is the only route into the lab.
  When its daemon is unhealthy, all remote admin is gone, even though every
  service is up.
- **No monitoring of the access path.** Prometheus runs inside the lab and
  never crosses the tailnet, so it showed all green. The operator found the
  problem.
- **The first diagnosis was wrong.** At first the relay itself ("everything
  goes through Singapore") was blamed, and a hEX UDP 41641 port forward was
  proposed. That forward could not work: Biznet is CGNAT, and the design
  forbids inbound ports. The rebind was taken for a fix and relapsed 6 minutes
  later. The parallel-ping comparison should have been the first test.

## Action items

| # | Action | Type | Status |
| --- | --- | --- | --- |
| 1 | A second Tailscale subnet router on pve2, advertising the same routes (Tailscale HA failover). One sick gateway then no longer cuts off access, and either can be restarted without a fallback. Already an open item in design §9. | Prevent | **Done** 2026-10-09 (`3e488bb`): `admin-gw2`, CT 102 on pve2. Failover tested both ways: stopping either gateway's tailscaled gave a 55–75 s gap, then the other served (UIs 200 in 0.2 s, 59 ms, 0% loss). Limit: failover happens on *offline*, not on *degraded*, so a sick-but-online gateway, as in this incident, still needs the restart below. |
| 2 | Recovery procedure in a runbook | Mitigate | Declined (operator, 2026-10-09): the procedure below is enough, and the admin-gw README links here |
| 3 | Watch the access path itself (tailscaled metrics, alerts on DERP or peer errors) | Detect | Declined (operator): the operator is the only user of the path and notices at once; both gateways already have ping probes |
| 4 | Lab Wi-Fi AP on VLAN 40 (design §9, switch P6) | Reduce dependency | Declined (operator): the relay at ~55 ms is fine for admin UIs; reconsider only if admin at home feels slow |
| — | hEX port forward of UDP 41641 | — | Rejected: behind CGNAT it cannot give a direct path, and it breaks the zero-inbound principle |

## Recovery procedure

Applies when a gateway is online but degraded (hung UIs, high loss). An
offline gateway fails over by itself in about a minute.

```bash
# 1. Which gateway is serving, and is it the sick one? archive is the control:
#    it goes over the same relay but not through a gateway.
tailscale status --json | jq -r '.Peer[] | select(.PrimaryRoutes) | .HostName'
ping -c30 <serving gateway tailnet IP> & ping -c30 <archive tailnet IP> & wait
#    Gateway bad while archive is steady at ~55 ms: its tailscaled is degraded.

# 2. Restart it by hopping through the OTHER gateway's own tailnet IP
#    (peer-to-peer, not the broken subnet route). Tested 2026-10-09.
#    admin-gw  (CT 101 on pve3) sick:
ssh -J root@<admin-gw2 tailnet IP> root@10.10.10.13 'pct exec 101 -- systemctl restart tailscaled'
#    admin-gw2 (CT 102 on pve2) sick:
ssh -J root@<admin-gw tailnet IP> root@10.10.10.12 'pct exec 102 -- systemctl restart tailscaled'

# 3. Verify: the ping to the gateway is ~55 ms with 0% loss, and the UIs load.
```

`tailscale debug rebind` is **not** enough. It helped for 6 minutes on
2026-10-09, then the problem came back. On 2026-10-09 there was only one
gateway, so the restart had to be covered by an armed fallback
(`systemd-run --on-active=240 pct reboot 101` on pve3). With the pair, the
other gateway serves while one restarts.
