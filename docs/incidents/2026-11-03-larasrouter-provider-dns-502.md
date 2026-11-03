# 2026-11-03: larasrouter returned 502 and held customers' funds after DNS failures to its LLM provider

| | |
| --- | --- |
| **Status** | Mitigated 2026-11-03 (infra live). App fix committed locally, not yet released. Upstream DNS decision open. |
| **Impact** | Three chat requests in 24 h got `502` from `larasrouter-api` because the pod could not open a connection to the LLM provider. Each request's reservation was held for reconciliation, and a customer's SDK retries got `402 insufficient_credit_reserved` for a few minutes. Other outbound calls from the same cluster (payments, email) showed the same failure class. |
| **Duration** | Three LLM-provider failures between 10:47 and 12:44 UTC on 2026-11-03. Payment and email lookups failed intermittently over the same 24–36 h window. |
| **Trigger** | The household ISP intercepts all DNS on port 53. Its resolver answers for any destination, and it loses a few percent of queries. |
| **Root cause** | Three things compounded. (1) The ISP's interceptor is lossy and slow for UDP/53. (2) Pods inherited a search domain the DMZ can never resolve, which doubled the lookups sent out. (3) A failed dial was treated like an ambiguous transport failure, so the app held funds for a request that was never sent. |

## Timeline

Times are UTC. WIB is UTC+7.

| UTC | Event |
| --- | --- |
| 10:47:38 | Chat request on rev 00038: the provider lookup timed out after the 3 s dial budget. The request was held and returned 502. |
| 10:47–10:50 | Payment-provider and email lookups also timed out. About 40 such failures are in the outbound log for the window. |
| 10:53:21 | The 5-minute unresolved-hold sweep wrote off the hold from 10:47. |
| 11:06:18 | Same failure on the other pod. Held, 502. The SDK's retries got 402 from 11:06:36 to 11:07:03. |
| 11:11:21 | The sweep wrote off the 11:06 hold. |
| 12:44:44 | The provider's connection was reset after the lookup had succeeded, so the request may have arrived. Held, 502, and correctly so. Retries got 402 from 12:44:54. |
| 12:50:22 | The sweep wrote off the 12:44 hold. |
| 14:15 | Investigation starts: DNS probes, CoreDNS metrics, and the router's counters. |
| 15:03–15:09 | Infra fix applied: `home.arpa` answered locally, pods' resolver file without a search list, the server and then the worker restarted one at a time. |
| about 15:20 | Verified: 30 `home.arpa` queries forwarded 0 upstream. |

## What the logs show

- Every 502 had one failed outbound attempt and no retry. The failure was either `dial tcp: lookup api.deepseek.com: i/o timeout` after 3.0 s, or `connection reset by peer` after 2.7 s.
- Each 502 was followed by a `request held for reconciliation` with `provider_unreachable`.
- The hold was written off after the 5-minute `unresolvedHoldWindow`. `reconciliationWindow` (24 h) is not what governs this path.
- Over the 24 h window: 109 of 112 outbound provider calls succeeded. Inbound chat requests: 107 succeeded, 3 were 502, 10 were 402, and the rest were 400, 401 or 404.

## Root cause, layer by layer

**1. Trigger: the ISP intercepts DNS.** Queries to 1.1.1.1, 9.9.9.9 and 8.8.8.8 all answer `id.server = noc-dev`, from the same resolver. Addresses that run no DNS service answered port 53 too. A blocked domain (`vimeo.com`) resolved to the ISP's block page, while DNS over HTTPS (DoH) gave the real address. Measured loss was 4–7% in some runs and 0% in others. Median latency was 40–105 ms. ICMP to the same addresses had 0% loss and 17 ms RTT. The DMZ and MGMT measured the same, so the cause is outside the cluster and the DMZ.

**2. Amplifier: pods looked up a name that can never resolve.** `services/k3s` gets its DNS servers from cloud-init, and cloud-init copies pve2's `search home.arpa`. Kubelet passed that into every pod, with `ndots:5`. So `api.deepseek.com` also went upstream as `api.deepseek.com.home.arpa` (A and AAAA). The DMZ cannot resolve `home.arpa` (the hEX drops DMZ DNS), so those lookups were pure waste. They were 7,833 of the 8,147 upstream-failure lines CoreDNS logged over about 70 h, about 96%.

**3. Budget: one lost packet used the whole dial budget.** CoreDNS forwards with a 2 s read timeout. The histogram had no answer after 2.048 s out of about 1.4 million upstream answers. The app's dial timeout is 3 s, and it covers the DNS lookup plus the TCP connect. One lost packet on the first upstream therefore left almost no time for the second.

**4. Harm: the app held funds for a request that was never sent.** `internal/inference/service.go` held the reservation for any transport error. A failed dial has written no bytes, so the provider cannot have billed it. The hold then made the SDK's retries fail with `402 insufficient_credit_reserved`, which also stopped the SDK's own retry from working.

The reset at 12:44 is different. The lookup had succeeded and the connection opened, so the request may have arrived. Holding funds there is correct, and the app change keeps that hold.

## What was ruled out

- DMZ queue drops: zero at the failure minutes. The queue dropped packets on other days, see below.
- WAN ICMP loss: zero at the failure minutes.
- Node conntrack: zero insert failures or drops over 72 h.
- UDP buffer errors: zero.
- Router CPU: p99 6%.
- TCP retransmits: normal.
- One bad pod: the three failures hit two different pods.

## Fix

**Infra (this repo), live and verified:**

- `services/k3s/install.sh` now:
  - Writes `/etc/rancher/k3s/resolv.conf` (nameservers only, no search list) and sets k3s `resolv-conf` to it. New pods no longer inherit `home.arpa`.
  - On the server, writes the k3s server manifest `homeserver-coredns-custom.yaml`: a `template ANY ANY home.arpa { rcode NXDOMAIN }` override. CoreDNS answers `home.arpa` locally.
- Applied through `proxmox/opentofu` with `-target`, one node at a time: the server, then the worker. `ai_converge` was not touched. Its plan change is still pending the operator's go-ahead.
- ADR [0031](../decisions/0031-cluster-dns-without-the-node-search-domain.md) records the decision.

**App (larasrouter, branch `fix/provider-unsent-retry`, commit `98424b8`, local only):**

- A dial failure is retried once, because no bytes were written, so a retry cannot reach the provider twice.
- A dial failure that is still refused is released as `provider_not_reached` (settled, zero charge), not held.
- The customer gets `503` with `Retry-After: 1`, not `502`.
- Any failure after the connection opened is still held.
- Unit tests cover the retry, the give-up, no retry after a write, the missing credential, the release decision and the 503 mapping. The integration test for an unreachable provider now expects 503, `Retry-After`, and a settled request with reason `provider_not_reached`.
- Full `go test ./...` passes (33 packages). Not deployed: the release needs a tag from the operator.

## Verification

- `home.arpa` queries through the cluster DNS: 30 queries, all NXDOMAIN in about 4 ms, zero upstream forwards.
- Real names still resolve through the cluster DNS.
- New pods' resolver files have no `home.arpa`.
- Both k3s nodes Ready after the change. The worker's CoreDNS pod came up after a stuck image pull; the old pod kept serving because the rollout was set to `maxUnavailable: 0`.
- `proxmox/opentofu` plans `No changes` for `k3s_server` and `k3s_worker`.

## Open

- **Upstream resolver (operator's decision).** Encrypted DNS (DoT) to 1.1.1.1 or 9.9.9.9 is not intercepted and measured with no loss. Using it would also bypass the ISP's blocklist for tenant workloads, which is a policy question. A repo-owned CoreDNS with a forward timeout under 2 s and two replicas goes with it. Today CoreDNS runs one replica.
- **App release.** Tag and deploy `services/api` once reviewed. The release needs the operator's go-ahead.
- **Image pulls on nodes.** Node-level lookups still use the host resolver through the same ISP path. A worker image pull failed with `Try again` at 15:03 and succeeded on retry. A DoT or host-resolver change would fix this too, and it is part of the same decision.
- **Monitoring.** CoreDNS metrics (`:9153`) are not scraped. The blackbox DNS probe runs from MGMT and cannot see this. Add a scrape of CoreDNS SERVFAIL and healthcheck metrics (ADR 0008), and a `provider_unreachable` holds-per-hour alert in larasrouter.
- **Doc correction.** `network-design.md` §2 said DMZ guests use public resolvers. They do, but the ISP answers for them. Corrected there.

## Unrelated findings

- **Tenant service down (not a platform fault).** One tenant service has never been ready on the home cluster: all 18 of its revisions, from 2026-10-15, are not ready. Its revisions crash on start (`DJANGO_SECRET_KEY` is not set), and the platform holds no environment variables for that service. Its crash-looping pods hold the namespace's ephemeral-storage quota (4 Gi), so the newest revision cannot create pods (`FailedCreate: exceeded quota`). The failures predate this incident, and the k3s restart only raised the error count. Not related to DNS. Needs the owner's configuration, and an operator decision on the crash-looping pods.
- **DMZ queue drops.** The hEX's DMZ queue dropped 3–12 million packets a day from 2026-10-14 to 2026-11-01, then stopped on 11-02. Unexplained. Needs its own look.
- **Tenant traffic.** Pods resolved names belonging to bandwidth-reselling software and a monitoring agent. Worth an abuse review.
