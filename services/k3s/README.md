# k3s — Kubeletto's tenant cluster

Two VMs in the DMZ (VLAN 25), K3s **v1.35.5+k3s1** (the rented cluster's
version), built by `proxmox/opentofu/k3s.tf` → `install.sh`. Why VMs and why
here: [ADR 0004](../../docs/decisions/0004-public-ingress-cloudflare-tunnel.md);
the move itself (deadline 2026-11-05): README Status.

| Node | VM | Where | Role | Size |
| --- | --- | --- | --- | --- |
| `k3s` | 300 | pve2, 10.10.25.20 | server: control plane, Kubeletto's platform, everything stateful | 4 vCPU, 5 GB (allocatable 3.5 CPU / 3.8 GiB), 40 GB |
| `k3s-worker` | 301 | pve3, 10.10.25.21 | agent: tenant pods and builds (stateless; disk not backed up) | 4 vCPU, 3 GB (allocatable 3.5 CPU / 2.3 GiB), 36 GB |

Both VMs stay on the laptops: pve1 runs on demand and takes no always-on
service ([ADR 0012](../../docs/decisions/0012-pve1-on-demand-ai-workstation.md)).

## Access

No SSH on either VM (tenant code runs there; the admin key opens the
Proxmox nodes). Everything goes through the guest agent:

```bash
ssh root@10.10.10.12 'qm guest exec 300 -- /usr/local/bin/k3s kubectl get nodes'
ssh root@10.10.10.12 'qm terminal 300'     # serial console (no password login)
```

The kubeconfig is root-only on `k3s` (`/etc/rancher/k3s/k3s.yaml`, 0600); it
is not copied anywhere yet.

## Config (install.sh)

Parity with the rented cluster: bundled Traefik disabled (Kubeletto runs its
own), ServiceLB on, `pod-max-pids=1024`, Kubeletto's registry mirror
(`registries.yaml`: `registry.kubeletto.com` → the in-cluster registry
Service at the pinned ClusterIP `10.43.229.215`, so the default service CIDR
`10.43.0.0/16` must stay). Deliberately different: **secrets encryption at
rest on**, kubeconfig 0600, no debug logging, kubelet reservations sized for
5 GB / 3 GB (server 512 Mi + 512 Mi, worker 256 Mi + 256 Mi).

Two join tokens (`random_password`, encrypted state), sent on the guest
agent's stdin, stored 0600:

- the **server token** (`k3s_token`) joins control-plane nodes — effectively
  cluster admin — and exists only on `k3s`;
- the **agent token** (`k3s_agent_token`) joins workers only; it is the one
  token `k3s-worker` (tenant code) holds. `install.sh` refuses a server
  token on an agent.

**Changing either token on the live cluster:** not through config alone.
K3s rewrites `server/cred/passwd` on disk but not its datastore copy, and the
second restart fails with "passwd newer than datastore"
([incident](../../docs/incidents/2026-10-11-k3s-passwd-newer-than-datastore.md)).
Use `k3s token rotate` on the server (it re-saves the bootstrap files), then
a test restart.

The registry mirror is plain HTTP to a pinned ClusterIP, as on the rented
cluster. Accepted: Kubeletto stamps every tenant image as
`registry.kubeletto.com/...@sha256:<digest>` and containerd verifies pulled
content against the digest, so whoever answers on that IP can deny an image
but not substitute one; claiming the IP needs Kubernetes API rights tenants
do not have.

## Placement rule for Kubeletto (decided 2026-10-11)

**Platform components run on `k3s`; tenants and builds on `k3s-worker`.**
Pods leave the VMs masqueraded to the node IP, and only `10.10.25.20` passes
the hEX pinhole and `pg_hba` to Postgres (verified: a pod on the worker is
blocked, on the server it connects). So Kubeletto's platform manifests get
`nodeSelector: node-role.kubernetes.io/control-plane: "true"` at the
rehearsal. It is also the trust boundary: tenant code and platform code on
different VMs.

Enforced since 2026-10-11: `k3s` carries the taint
`node-role.kubernetes.io/control-plane:NoSchedule`, so a pod without a
matching toleration (every tenant pod) can only land on `k3s-worker`.
Platform manifests need both the `nodeSelector` and the toleration
(`services/cloudflared/deploy.sh` is the example). K3s's own system pods
already tolerate it.

## Anti-spoofing (Proxmox firewall)

Both VMs share VLAN 25, and the worker runs tenant code. Each NIC has the
Proxmox firewall on with ipfilter + macfilter (`proxmox/opentofu/firewall.tf`):
a VM may send only from its own address (its `ipfilter-net0` ipset) and MAC,
so the worker cannot claim `10.10.25.20` and pass the Postgres pinhole.
Policies are ACCEPT; the filter is the protection. This needs the datacenter
firewall on, with every host's own firewall explicitly off
(`files/pve-firewall.sh`). Containers are unaffected (their NICs have
`firewall=0`). Consequence: no floating address (kube-vip, MetalLB L2) on these
NICs without an ipset entry. Rollback: `pvesh set /cluster/firewall/options --enable 0`.

## Verified (2026-10-11)

Both nodes Ready; secrets encryption Enabled; pods on both nodes resolve
public DNS, reach HTTPS and the in-cluster API, and cannot reach Proxmox;
Postgres reachable from the server's pods only. `qm stop/start` of both VMs:
both nodes Ready again. Anti-spoofing: a spoofed `10.10.25.99` on the worker
cannot reach the gateway (100 % loss, the ipfilter DROP counter rises) while
its real address can; nodes, pods, Postgres from the server and the icmp
probes unaffected.

## Growing a node's disk

`proxmox/opentofu/k3s.tf` sets each VM's disk size; a bigger `size` is an
in-place, online resize (`tofu apply -target=...`). The guest then needs its
root partition and filesystem grown, once, by hand (cloud-init only grows them
on first boot):

```bash
ssh root@<node> "qm guest exec <vmid> -- sh -c 'growpart /dev/sda 1 && resize2fs /dev/sda1 && df -h /'"
```

Done 2026-10-14 for `k3s-worker` (30 to 36 GB, room for the build cache): the
worker holds the tenant images and the per-service build caches, and pve3's thin
pool (54 GB, ~61 % used) is already overcommitted by its virtual disks, so grow
in small steps and keep `ThinPoolFilling` (85 %) in mind.

## The worker's disk budget (build cache)

The worker's 36 GB hold the OS (~3 GB), the tenant images in containerd
(~20 GB for ~90 images) and, since 2026-10-14, Kubeletto's per-service build
caches: the three most recently built services each keep BuildKit's state on
a `local-path` claim (`buildcache-<service uuid>` in `kubeletto-builds`,
under `/var/lib/rancher/k3s/storage`). The bounds, all in the Kubeletto
repo's home overlay and `buildkitd-config`:

| Bound | Value | Why |
| --- | --- | --- |
| Caches | 3 services (claims beyond, or unused 14 days, are deleted at the next build) | `BUILD_CACHE_MAX_SERVICES`; the build quota allows 4 claims |
| Per cache | 1.5 GB (`maxUsedSpace`) | a Go or Node build's base image, dependencies and build cache fit |
| Free space | caches shrink to 256 MB when the disk has under 6 GB free | before the kubelet's image GC (85 % used, ~5.4 GB free) evicts tenant images, which would make scale-from-zero pull from R2 |

So the caches cost at most ~4.5 GB. A lost cache only makes the next build of
that service cold (measured on this worker: a Go build 128 s cold, 6 s warm).
