# 2026-11-06: Slow home downlink, large API requests cut with 499

| | |
| --- | --- |
| **Status** | Mitigated 2026-11-06 00:21 WIB (Traefik read timeout raised). The slow line itself is open with the ISP. |
| **Impact** | Large requests to the larasrouter API failed now and then. An agent sending 6 MB requests (its whole conversation each turn) saw `499 Client Closed Request` when an upload took more than 60 s. Smaller requests were slow to arrive but succeeded. Any tenant app receiving large uploads was exposed the same way. |
| **Duration** | Seen 2026-11-06 00:01 WIB (operator testing). How long the line had been slow is not known: there is no bandwidth monitoring. |
| **Trigger** | The home internet download fell to about 1.3–3 Mbit/s. It is normally about 90 Mbit/s (`docs/design/network-design.md`). |
| **Root cause** | Two things together. (1) Every public request reaches the lab through the Cloudflare tunnel, so a request body arrives at the home line's *download* speed. (2) Traefik v3 bounds reading a whole request, body included, at 60 s by default (`respondingTimeouts.readTimeout`); Kubeletto's values never set it. At ~150 KB/s, a 6.3 MB body needs more than 60 s. |
| **Fix** | Kubeletto repo `c9299e4c` (branch `fix/traefik-read-timeout`, unpushed): `readTimeout: 300s` on the `websecure` entry point, applied with `services/kubeletto/apply.sh traefik`. |

## Timeline (WIB)

| Time | Event |
| --- | --- |
| 00:00:47 | An agent request (6.2 MB) succeeds after 56.6 s. About 38 s of that is the body arriving; the provider takes 17.5 s. |
| 00:01:44 → 00:02:44 | The next agent request (6.3 MB) is cut at exactly 60.0 s. Traefik logs `DownstreamStatus 499`; the larasrouter API logs `400 BODY_INCOMPLETE` at 60.035 s (the body stream ended early) and never calls a provider. The client shows Traefik's `499 Client Closed Request`. |
| 00:03 | The operator reports the error and asks whether it is larasrouter or the client. |
| 00:05 – 00:17 | Diagnosis, read-only (see Evidence). |
| 00:21 | Traefik rolled out with `readTimeout=300s` (`maxUnavailable: 0`; the new pod's first second returned three 502s to tenant apps while its routes loaded). |
| 00:22 – 00:24 | Verified: a 10.5 MB upload through the tunnel took 91.7 s and reached the API in full. |

## Evidence

- Upload through the tunnel to the API, a body the API reads in full and then refuses: 1 MB in 7.7 s, 6 MB in 38.3 s, which is 130–156 KB/s. The same Mac uploads to Cloudflare directly at 3–6.5 MB/s, so the client side was not the limit.
- Download speed from the lab, which skips the tunnel: pve2 ~400 KB/s, pve3 ~300 KB/s, VM 300 ~220 KB/s, tested against Cloudflare, OVH and jsDelivr. The tunnel was no slower than any other download into the lab.
- The hEX was not the cause:
  - ether1 linked at 100 Mbps full duplex, with zero FCS errors, drops or collisions;
  - CPU at 2%, and 4.9 Mbit/s on ether1 in total;
  - ping to 1.1.1.1 about 20 ms and to 8.8.8.8 about 25 ms, both with 0% loss.

  Low latency with very little throughput points at the ISP.
- Both `cloudflared` connectors were healthy: QUIC, and no connection errors in the previous 2 h.
- Before the change, the rendered Traefik chart (41.7.1) matched the live Deployment argument for argument. After it, the only difference was the one new argument.

## Analysis

larasrouter already times its own uploads for slow clients. It allows 30 s without a byte and 2 min in total, and answers 408, which clients retry. Traefik's 60 s default was shorter than that, and it answered with a 499 that clients don't recognise as a timeout. `readTimeout` only covers reading the request. Responses and long streams are unaffected, and Cloudflare in front still holds the slow-client side.

The new ceiling does not make a slow line fast. At 150 KB/s, a 6 MB request still takes about 40 s before the model starts. Cloudflare's own limits on how long the origin may take to answer are outside the lab's control.

## Action items

- [ ] Operator: restart the Biznet modem, run a speed test from the LAN, and report the line to Biznet if it is still near 2 Mbit/s.
- [ ] Merge `fix/traefik-read-timeout` into the Kubeletto `main` and any branch used for `apply.sh`. Applying from a branch without it puts the 60 s default back.
- [ ] Consider a WAN throughput probe (for example, a scheduled small download measured by the blackbox exporter), so a degraded line raises an alert before a customer runs into it.
