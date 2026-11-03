# 0031 — Cluster DNS: pods drop the node's search domain, and `home.arpa` is answered locally

**Status:** accepted (2026-11-03). Corrects the DMZ DNS statement in [`network-design.md`](../design/network-design.md) §2. Follows the incident [2026-11-03](../incidents/2026-11-03-larasrouter-provider-dns-502.md). It does not decide the upstream resolver: that is open, see Consequences.

## Context

- The K3s VMs take DNS servers from cloud-init, and cloud-init also copies pve2's search domain, `home.arpa`. Kubelet passes the node's search list into every pod, with `ndots:5`.
- The DMZ can never resolve `home.arpa`: the hEX drops DMZ DNS (design §2). So every external lookup from a pod also sent `<name>.home.arpa` A and AAAA queries upstream. Those lookups were about 96% of the upstream-failure lines CoreDNS logged over about 70 hours.
- The DMZ's "public resolvers" (1.1.1.1 and 9.9.9.9) are answered by the household ISP's DNS interceptor on port 53, for any destination. It loses 4–7% of queries in some runs. Each loss costs CoreDNS's 2 s forward timeout. Encrypted DNS (DoT on 853) is not intercepted, and measured with no loss.

## Decision

1. **Nodes hand pods a resolver file with no search list.** `services/k3s/install.sh` writes `/etc/rancher/k3s/resolv.conf` (nameservers only) and sets k3s `resolv-conf` to it on both nodes. Pods from then on get `search <ns>.svc.cluster.local svc.cluster.local cluster.local` and no `home.arpa`. Running pods keep their old list until they are recreated, which is harmless now (decision 2).
2. **CoreDNS answers `home.arpa` locally with NXDOMAIN.** The server role of `install.sh` writes a k3s server manifest, `homeserver-coredns-custom.yaml`. It holds the `coredns-custom` ConfigMap with a `template ANY ANY home.arpa { rcode NXDOMAIN }` override. k3s mounts the ConfigMap as optional and imports `*.override` inside the `.:53` block. Nothing legitimate lives under `home.arpa`: the DMZ cannot resolve it, and no platform config uses it (checked in both repos).
3. **The upstream resolver is unchanged.** Plain UDP to 1.1.1.1 and 9.9.9.9 stays for now.
4. **The application handles the remaining loss.** A connection that never opens is retried once in larasrouter. If it still fails, the request is released, not held, and the customer gets a 503 with `Retry-After`. This is a separate repo and release; see the incident.

## Consequences

- Measured after the change: 30 `home.arpa` queries (A and AAAA) through the cluster DNS returned NXDOMAIN in about 4 ms and added zero upstream forwards. Real names still resolve.
- **Open (operator's decision):** encrypted upstream. DoT would also bypass the ISP's blocklist for tenant workloads, which is a policy question, so it is not made here. The same decision covers a repo-owned CoreDNS with a forward timeout below 2 s and two replicas. Today CoreDNS runs one replica, and the forward timeout is the lever for loss.
- Node-level lookups, such as containerd's image pulls, still use the host's resolver through systemd-resolved, which goes to the same interceptor. A worker's image pull failed on 2026-11-03 for that reason, and the kubelet retried it. This ADR does not change the host resolver.
- A change to `install.sh` restarts k3s on each node, and the restart is what makes the change take effect. The restart leaves running pods alone. The first run of this change restarted the server, which made the Kubernetes API briefly unavailable, and then the worker, one node at a time.

## Verification

- Both nodes Ready after each restart. The worker's CoreDNS pod came up after one stuck pull (the pod was replaced; the old one kept serving because the rollout was set to `maxUnavailable: 0`).
- The live k3s manifest and the repo copy match. `proxmox/opentofu` plans `No changes` for `k3s_server` and `k3s_worker`.
- The `ai_converge` change is still pending and was not applied; it is not part of this decision.
