# DMZ isolation audit: what tenant code can reach (2026-11-06)

Question: Kubeletto runs other people's code in pods on the K3s worker (VM 301,
VLAN 25, the DMZ) inside the house's network. What can that code reach, and
what stops it? Part of the platform operating model, Phase 3 (Kubeletto repo,
`docs/design/platform-operating-model.md`, D19).

## Method

1. Read the router firewall as code (`network/routeros/firewall.tf`).
2. `tofu plan` of `network/routeros` against the live hEX (read-only,
   `-lock=false`): **"No changes. Your infrastructure matches the
   configuration."** So the code below is what is live.
3. Read, on the live cluster, one tenant namespace's NetworkPolicy, its Pod
   Security labels and its container's security context.

Not done: no packet was sent from a tenant pod to check the policies hold
(see "Not tested").

## What a tenant pod can reach

| Layer | Rule | What it means |
| --- | --- | --- |
| Router, forward | `forward_drop_inter_vlan`: default deny between VLANs | A DMZ host reaches no other VLAN unless an exact rule says so |
| Router, forward | Pinholes, one rule each, exact source, destination and port: VM 300 (server) to Postgres 5432, NATS 7422, Valkey 6380; **VM 301 (worker) to Postgres 5432 and Valkey 6381** (larasrouter, ADR 0022) | The server's pinholes are not the worker's. The worker's two apply to every pod on it at the router level |
| Router, forward | `forward_no_biznet`, `forward_dmz_no_private`, `forward_dmz_no_smtp` | The DMZ cannot reach the household LAN or ISP private ranges via the WAN, and cannot send mail (port 25) |
| Router, forward | `forward_lan_wan`: internet for the lab | Everything else leaves through the household's public address |
| Router, input | `input_admin` (SSH 22, REST/WebFig 443, WinBox 8291) accepts only the `admin-src` list: TRUSTED, MGMT, native. `input_dmz_dns_*` drops DMZ DNS to the router. `input_drop` drops the rest | From the DMZ the router answers ping and nothing else |
| Cluster, NetworkPolicy `kubeletto-base-policy` (live, a tenant namespace) | Egress only to DNS in `kube-system`, to its own namespace, `knative-serving` and `kourier-system`, and to the internet except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10` and the household's public IPv4 /32, on ports 80, 443, 5432, 6543, 3306, 27017, 6379 (the free tier's list) | A tenant pod cannot address any lab VLAN (`10.10.x.x` is inside `10.0.0.0/8`) nor the household's own public address |
| Cluster, Pod Security | `enforce=baseline`, `audit=restricted`, `warn=restricted` | Privileged pods, host namespaces and host paths are refused; the stricter profile only logs and warns |
| Container | `allowPrivilegeEscalation: false`, capability `NET_RAW` dropped, seccomp `RuntimeDefault`; service-account token not mounted | A smaller kernel surface than a default pod |

## Findings

1. **The worker's Postgres and Valkey pinholes are only as strong as the
   namespace NetworkPolicy.** The router lets any pod on VM 301 open
   `10.10.20.x:5432` and `:6381`. What stops every tenant except larasrouter
   is the base NetworkPolicy (private ranges blocked) and, at the data end,
   `pg_hba` and the Valkey password. A tenant namespace that lacks the policy
   would be reachable at the network level. Recommended: an alert for a `kl-*`
   namespace without `kubeletto-base-policy` (kube-state-metrics has the
   NetworkPolicy series). Not built.
2. **Pod Security is `baseline`, not `restricted`.** Moving `enforce` to
   `restricted` needs `runAsNonRoot` and all capabilities dropped; customer
   images often run as root and would stop starting. The operating model's
   "restricted on every tenant namespace" is therefore a target to measure
   (what do the `audit=restricted` violations show?) before it is a switch.
3. **Capabilities: only `NET_RAW` is dropped.** `baseline` allows the default
   set (CHOWN, SETUID, DAC_OVERRIDE and so on). Dropping `ALL` is a candidate
   hardening, but some images chown or setuid at start: canary first.
4. **Internet egress is wide at the router** (everything but SMTP and private
   ranges); the narrowing to seven ports for free tenants lives only in the
   NetworkPolicy. That matches D2 (paid plans are not port-limited); noting it
   because the router would not catch a missing policy (finding 1).

## Not tested

- A probe from a tenant-like pod, to confirm the private ranges are
  unreachable and that the CNI enforces NetworkPolicy. This audit read the
  policy objects; it did not send packets. The first Phase 3 test should: a
  scratch namespace with the base policy, one pod, `nc` to `10.10.20.x:5432`,
  the router (`10.10.25.1`), the Proxmox UI and a lab DNS name.
- Other tenant namespaces: one of the 246 was read. Finding 1's alert
  would cover that.
- IPv6: the DMZ has none and K3s pods are IPv4-only, so it was not examined.
