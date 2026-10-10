# k3s — Kubeletto's tenant cluster

Two VMs in the DMZ (VLAN 25), K3s **v1.35.5+k3s1** (the rented cluster's
version), built by `proxmox/opentofu/k3s.tf` → `install.sh`. Why VMs and why
here: [ADR 0004](../../docs/decisions/0004-public-ingress-cloudflare-tunnel.md);
the move itself (deadline 2026-11-05): README Status.

| Node | VM | Where | Role | Size |
| --- | --- | --- | --- | --- |
| `k3s` | 300 | pve2, 10.10.25.20 | server: control plane, Kubeletto's platform, everything stateful | 4 vCPU, 5 GB (allocatable 3.5 CPU / 3.8 GiB), 40 GB |
| `k3s-worker` | 301 | pve3, 10.10.25.21 | agent: tenant pods and builds (stateless; disk not backed up) | 4 vCPU, 3 GB (allocatable 3.5 CPU / 2.3 GiB), 30 GB |

`k3s` moves to pve1 when pve1 is built (offline migration: `cpu.type = host`).

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

The join token is `random_password.k3s_token` (encrypted state), sent to the
guests on the agent's stdin and stored in `/etc/rancher/k3s/token` (0600).

## Placement rule for Kubeletto (decided 2026-10-11)

**Platform components run on `k3s`; tenants and builds on `k3s-worker`.**
Pods leave the VMs masqueraded to the node IP, and only `10.10.25.20` passes
the hEX pinhole and `pg_hba` to Postgres (verified: a pod on the worker is
blocked, on the server it connects). So Kubeletto's platform manifests get
`nodeSelector: node-role.kubernetes.io/control-plane: "true"` at the
rehearsal. It is also the trust boundary: tenant code and platform code on
different VMs.

## Open before tenant workloads run

The VMs' NICs have the Proxmox firewall off: the worker could claim
`10.10.25.20` inside VLAN 25 and pass the Postgres pinhole (pg_hba still
wants the password). Fix: per-VM firewall with ipfilter/macfilter (needs the
datacenter firewall on, hosts' own firewalls off) — its own change, before
the rehearsal deploys tenants.

## Verified (2026-10-11)

Both nodes Ready; secrets encryption Enabled; pods on both nodes resolve
public DNS, reach HTTPS and the in-cluster API, and cannot reach Proxmox;
Postgres reachable from the server's pods only. `qm stop/start` of both VMs:
both nodes Ready again.
