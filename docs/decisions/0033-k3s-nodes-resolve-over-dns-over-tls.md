# 0033 — K3s nodes resolve over DNS over TLS (node only; pods unchanged)

**Status:** accepted (2026-11-08). Narrows the open "encrypted upstream" item of [ADR 0031](0031-cluster-dns-without-the-node-search-domain.md) to the nodes' own resolver. The pod path (CoreDNS) is still open there.

## Context

- The ISP answers every outbound UDP/53 packet and loses 4–7% of them in some runs (ADR 0031). The K3s VMs' systemd-resolved sends plain UDP to 1.1.1.1 and 9.9.9.9, so the node's own lookups pass through it. Those are containerd's image pulls, kubelet and apt.
- 2026-11-08, larasrouter v0.1.30: both new pods on `k3s-worker` failed their first pull with `dial tcp: lookup ghcr.io: Try again`, and the second blob with `lookup pkg-containers.githubusercontent.com: Try again` (06:38–06:45 UTC). The kubelet's back-off retry succeeded after about 7 minutes. The old revision kept serving, but the release CLI timed out and reported a failure. The same failure happened on 2026-11-03.
- DoT on 853 is not intercepted: 0 loss in 270 queries (2026-11-03, ADR 0031).
- ADR 0031 left DoT open because, for **tenant workloads**, it would also bypass the ISP's blocklist, which is a policy question. The nodes' own lookups are platform traffic (registries, OS updates), not tenant traffic, so that question does not arise for them.

## Decision

1. `services/k3s/install.sh` writes `/etc/systemd/resolved.conf.d/10-homeserver-dot.conf` on both nodes: `DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net` and `DNSOverTLS=opportunistic`. It restarts systemd-resolved only when the file changes. It never restarts k3s: the file is not in the script's k3s config set.
2. **Opportunistic, not strict.** If 853 stops working, resolved falls back to plain DNS, so the node keeps a lossy resolver instead of losing DNS. Strict mode would turn an ISP change into a cluster outage.
3. Pods are unchanged. They resolve through CoreDNS, which forwards plain UDP to the servers in `/etc/rancher/k3s/resolv.conf`. The policy question and the CoreDNS forward-timeout question from ADR 0031 stay open.

## Consequences

- Image pulls and other node lookups no longer depend on the intercepted path.
- In opportunistic mode, resolved does not verify the server certificate, so it protects against loss and interception, not against an active attacker who could forge the TLS session. That is acceptable for this purpose; strict mode would be the change if it ever matters.
- A future cloud-init rebuild of a node gets the file from `install.sh`, which Tofu runs on every node build.

## Verification (2026-11-08)

- `tofu apply -target=terraform_data.k3s_server -target=terraform_data.k3s_worker`, server first, then worker. `ai_converge` was left pending, as before.
- On both VM 300 and VM 301: `resolvectl status` shows `DNSOverTLS=opportunistic` with both server names. There are 2 established connections to port 853. 60 uncached `ghcr.io` lookups (cache flushed each time): 0 failures on each node. `k3s` / `k3s-agent` were not restarted; both nodes are Ready.
- The targeted plan reports `No changes`.
