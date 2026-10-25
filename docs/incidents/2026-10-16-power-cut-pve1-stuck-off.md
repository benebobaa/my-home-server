# 2026-10-16: Power cut; pve1 stayed off for three days

| | |
| --- | --- |
| **Status** | Resolved 2026-10-19 15:22 WIB |
| **Impact** | A mains power cut took the whole lab down at once: hEX, switch, pve1, pve2, pve3. Everything on pve2 and pve3 came back by itself within 14 minutes, including the Kubeletto public API (customer-facing, unreachable about 17:45–17:59). The archive (CT 110) needed a manual start (`onboot: 0` by design). pve1 did **not** come back: the `ai` VM and the Hermes Telegram bot were offline for about 70 hours. Nothing was found lost; that check covers services answering their probes and pve1's root filesystem recovering itself, nothing deeper. |
| **Duration** | Lab: 2026-10-16 17:45–17:59 WIB. pve1: 2026-10-16 17:45 → 2026-10-19 15:21 WIB |
| **Trigger** | Mains power loss for about 10 minutes (17:45–17:55). There is no UPS, and the laptop batteries are dead. |
| **Root cause** | After power returned, pve1's standby power was stuck: the power button, "Restore AC Power Loss = Last State" and Wake-on-LAN all depend on it, and all three did nothing. Only removing AC at the PSU switch cleared it. |
| **Fix** | The operator switched the PSU off and on, and pve1 booted. |

## Timeline (WIB)

| Time | Event |
| --- | --- |
| 10-16 17:44:27 | The last entry pve1 wrote to its journal before the cut (pve2 17:43:34, pve3 17:44:08). The journal is only written to disk every few minutes, so these are not the moment of the cut. |
| 10-16 ~17:45 | Power lost. The last successful Prometheus scrapes are at 17:44:57–17:45:08 for all four hosts. Neither node has a clean shutdown sequence in its journal. |
| 10-16 17:55:35 | The hEX boots (from its uptime). |
| 10-16 17:55:49 / :52 | pve3 and pve2 boot by themselves, 3 s apart. Their clocks start at 2026-04-14 because the laptops lose their RTC without AC; about 30 s later chrony steps them by 16,039,07x s. |
| 10-16 17:57:30 – 17:59:30 | The monitoring stack comes back (it shares the power, so it saw nothing in between). Then the admin gateways, PBS, Postgres and NATS. The Kubeletto API answers at 17:59:00, registry auth and K3s HTTP at 17:59:30. Two platform pods (`kourier-gateway`, `health-proxy`) restart once. |
| 10-16 18:19 | `root@pam` starts the archive (CT 110) by hand. Its mounts, which come from pve2's fstab (`nofail`), are present. |
| 10-16 → 10-19 | pve1 stays off. Only `info` alerts fire for it (`PveNodeDown`, `HostUnreachable` for `ai`/`hermes`), which are silent by design (ADR 0012), so nobody is told. |
| 10-19 ~14:55 | The operator presses Wake-on-LAN in the PVE UI. Nothing happens. |
| 10-19 14:57–15:22 | The agent sends magic packets six times, from both pve2 and pve3: the API call the UI button makes, broadcast on ports 9 and 7, and unicast. pve1 never answers even ARP. The agent wrongly blames the NIC not being armed after an AC loss (see Analysis). |
| 10-19 ~15:20 | The operator presses pve1's power button: no lights, no fans. They switch the PSU off and on. |
| 10-19 15:21:29 | pve1 boots. Its root filesystem runs an ext4 orphan cleanup; `ai` (VM 140) and `hermes` (CT 141) start (`onboot`); `nic0` shows `Wake-on: g`; the cluster has 3 of 3 votes. Whether pve1 started on its own when power came back or from a button press is not known. |

## Analysis

The power button, the BIOS's "Restore AC Power Loss" and Wake-on-LAN all run
on standby power: the PSU's +5VSB rail, which feeds the board's embedded
controller and the NIC while the PC is off. A dead power button means that
layer was not working, so neither of the other two could have worked either.
That explains both surprises in one: pve1 did not restore power although it
was running when the power went, and it did not wake on any magic packet.

Switching the PSU off and on clears this kind of fault. Two causes behave that
way, and the evidence cannot tell them apart:

- **The PSU latched into protection.** A spike or brownout as power returned
  trips over- or under-voltage protection, and the PSU stays off until AC is
  removed.
- **The board's embedded controller hung in standby.** It needs a cold start,
  and losing AC is the only way to give it one.

Ruled out:

- **The BIOS lost its settings.** pve1's RTC was correct at boot
  (`RTC time: 08:21:35, date: 2026-10-19` UTC), and IOMMU was on (the GPU went
  to the `ai` VM as usual), so CMOS was not reset. This does not prove that
  "Restore AC Power Loss" still reads Last State: that value was not read.
- **The NIC was not armed.** This was the runbook's only explanation for a
  failed wake, and the agent repeated it as the diagnosis on 10-19. It could
  be true as well, but it cannot explain a dead power button. Relying on it
  delayed the trip to the PSU switch.

pve2 and pve3 came back by themselves when power returned. So did everything
on them that has `onboot: 1`: the K3s VM 300, Postgres, NATS, Valkey and
monitoring. This was the first cold boot of pve2 with the archive's mount
sources in fstab (`nofail`, since 2026-10-15). It booted, and the mounts were
present when CT 110 was started.

## Secondary findings

- **Nothing reported the outage.** Monitoring shares the power, so it was
  blind for the 12 minutes it mattered. Afterwards only `info` alerts fired,
  which are silent. The healthchecks.io dead-man's switch (5 min + 5 min
  grace) should have fired at about 17:55; whether it did was not checked.
- **The laptops reset their clocks on every power cut** (dead CMOS cells).
  chrony fixed it within 30 s here, but anything that starts before then sees
  April 2026.
- **The hEX's local log is useless for forensics.** Its 1,000-line buffer
  covers about two minutes, because the `dmz-private` drop rule logs every
  hit and the K3s server VM (300) hits it about 10 times a second.
  The router also ships its log to VictoriaLogs, so the history survives
  there. Something in the Kubeletto cluster keeps trying to reach private or
  CGNAT addresses through the WAN; that is not investigated here.

## Action items

- [x] `docs/runbooks/node-ops.md`: if a wake does nothing, try the power
      button; if that is dead too, switch the PSU off for 10 s and on. And
      the laptops power on by themselves after a power cut.
- [x] `docs/hardware.md`: pve1's restore-on-AC failed once; the value is
      still to be read in the BIOS.
- [ ] Operator, next time at the desk: in the BIOS (Advanced → APM), confirm
      **Restore AC Power Loss = Last State** and **ErP Ready = off**.
- [ ] Operator decision: this cold boot answers the open "boot path not yet
      proven by a cold reboot" item for the archive. Set CT 110 `onboot: 1`,
      or keep starting it by hand.
- [ ] Alert for a lab-wide power event (pve2 and pve3 boot time changes
      within the same few minutes): one `warning` saying to check that pve1
      came back and to start the archive. Proposal only.
- [ ] Check whether healthchecks.io notified at about 17:55 on 10-16.
- [ ] Find what in the K3s cluster sends traffic to non-public destinations
      (the `dmz-private` drops).
- [ ] UPS: still the standing item in `node-ops.md`. One would have covered
      a 10-minute cut.
