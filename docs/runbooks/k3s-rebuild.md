# Rebuild or restore the K3s server (VM 300)

VM 300 (`k3s`, pve2, `10.10.25.20`) is Kubeletto's control plane and the only
stateful part of its cluster: the K3s datastore, every Secret, the platform's
pods and, on its second disk, the registry's blobs. Tenant data is not here
(Postgres is CT 130; the worker, VM 301, is stateless). Written for the
operator, and for the second person who is meant to get break-glass access
within 12 months (Kubeletto operating model, D22). Target: back in service
within 2 hours.

**What is proven and what is not (2026-11-06).** Path A below is the supported
one: its backup exists, is nightly and was test-restored. Path B (nothing to
restore from) has two known gaps in the tools and has never been run end to
end: do not count on 2 hours for it.

No SSH on either VM (tenant code runs there). Everything goes through root SSH
to pve2 and the guest agent:

```bash
ssh root@10.10.10.12 'qm guest exec 300 -- /usr/local/bin/k3s kubectl get nodes'
ssh root@10.10.10.12 'qm terminal 300'      # serial console
```

## Path A: restore VM 300 from the replica backup (supported)

A second PBS server, `pbs-replica` (CT 112 on pve1), holds VM 300 with **both**
disks, nightly at 03:30 WIB ([ADR 0025](../decisions/0025-replica-backup-of-vm-300-on-pve1.md)).
The main `pbs` is excluded from VM 300 since 2026-10-28 and only has old copies.
Checked 2026-11-06: the newest replica backup was 2026-11-06 03:30 WIB, about
80 GiB; daily copies from 2 Nov were present.

1. **See what exists and how old it is** (that age is how much cluster state you
   can lose; tenant data in Postgres is not affected):
   ```bash
   ssh root@10.10.10.12
   qm status 300
   pvesm status --storage pbs-replica
   pvesm list pbs-replica --vmid 300 | tail -n 3
   ```
2. **Stop it and restore over it, same VMID, same MAC and address** (no
   `--unique`: a copy with a new identity would not pass the Postgres pinhole
   or the Proxmox ipfilter):
   ```bash
   qm stop 300
   vol=$(pvesm list pbs-replica --vmid 300 | awk 'NR>1 {print $1}' | tail -1)
   qmrestore "$vol" 300 --storage local-lvm --force 1
   qm config 300 | grep -E 'scsi0|scsi1'      # both disks back (root + registry)
   qm start 300
   ```
   pve2's thin pool is the only one with room for both disks (about 40 GB each);
   check `lvs` first. A test restore of the 40 GB root disk took 106 seconds on
   2026-10-15; a restore with both disks has not been timed.
3. **Wait for the cluster to come back** (a few minutes; K3s starts by itself, the
   worker rejoins with its agent token):
   ```bash
   qm guest exec 300 -- /usr/local/bin/k3s kubectl get nodes          # both Ready
   qm guest exec 300 -- /usr/local/bin/k3s kubectl get pods -A | grep -v -E 'Running|Completed'
   ```
4. **Check the platform and the public path:** `curl -s https://api.kubeletto.com/healthz`;
   the `cloudflared` pods Running; the alerts `KubelettoPublicPathDown`,
   `K8sPlatformPodNotReady` clear (docs/runbooks/alerts.md).
5. **Compare the cluster with the repo** from the operator Mac:
   `cd services/kubeletto && ./apply.sh drift` and `./apply.sh nodes`. A diff here
   is what changed in the cluster after the backup (a deploy, a config change):
   read it, then `./apply.sh platform` if the repo is right. If `nodes` reports a
   MISSING node address, add that ipBlock to `infra/k8s/home/policies.yaml` or that
   node cannot pull tenant images.
6. **Tenant services deployed after the backup are missing from the cluster** but
   present in the database. Core's status reconciler marks a service whose
   Knative object is missing as Idled and its owner sees "redeploy required".
   The same reconciler caused the 2026-10-11 incident when it deleted services
   it could not schedule (Kubeletto decision D5), so watch it after a restore:
   check `usage_samples`/`runtime_services` counts against the day before, and
   redeploy affected services through the platform, not by hand.

Never start a restore under a new VMID with a real NIC "to compare": it would be
a second control plane with VM 300's address and the tunnel's credentials
(`docs/runbooks/backup-restore.md`, the VM 300 drill, shows how to test without a
NIC).

## Path B: nothing to restore from (best effort, not proven)

Only if VM 300 and every replica copy are gone. The tools were written for the
move from the rented server and have two gaps for this use:

- **Secrets.** `services/kubeletto/secrets.sh --from-snapshot` rebuilds the
  cluster's Secrets from `secrets.prod-snapshot.sops.json`, taken on 2026-10-14.
  Anything rotated since is not in it, and the home-generated passwords (NATS and
  others) are regenerated. There is no current export of the cluster's Secrets
  outside the VM backup itself.
- **Tenants.** `services/kubeletto/restore.sh list` captures the running
  services by SSH to the **rented server** (`103.59.160.198`), which was wiped
  after the move; its cache directory is empty. Without a list the tool cannot
  redeploy tenants.

The steps, in order, with those gaps marked:

1. Rebuild the VM: in `proxmox/opentofu`, `tofu apply -replace=proxmox_virtual_environment_vm.k3s`
   with `-target` (the full plan has not been clean on main; check `tofu plan`
   first). `install.sh` installs K3s with the same tokens (they are in the
   encrypted state). Wait for the worker to rejoin.
2. Registry blobs: file-level restore of the registry disk from `pbs-replica`
   (PVE UI, Backups, File Restore) if any copy exists; otherwise tenant images
   must be rebuilt by their owners.
3. Secrets: `./secrets.sh --from-snapshot` (gap above), then `./secrets.sh verify`.
4. The platform: `./apply.sh` then `./apply.sh drift`.
5. Tenants: gap above. The authoritative list of what should run is the
   database; a redeploy tool that reads it does not exist yet.

## What would make "2 hours" true for Path B (open work)

1. A scheduled, SOPS-encrypted export of the cluster's current Secrets (the
   existing snapshot is dated 2026-10-14).
2. `restore.sh list` reading the services from the home database instead of the
   rented server.
3. A full drill on a scratch VM of Path A (both disks, worker rejoin, `drift`,
   the reconciler's behaviour), timed; then of Path B.
4. Room on the main PBS: `pbs` is 85 % full (26.2 of 30.8 GiB, 3 GB free,
   2026-11-06; prune keeps 7 daily, 4 weekly and 6 monthly, GC runs daily, and
   `PveStorageFilling` fires at 90 %). VM 300 no longer lands there, but its old
   copies still sit in the 4 weekly / 6 monthly slots. Forgetting them would free
   room now that the replica holds VM 300: a deletion, so the operator's decision.

Related: `docs/runbooks/backup-restore.md` (PBS in general, the VM 300 test
restore), `services/k3s/README.md` (how the cluster is built, tokens, access),
`docs/runbooks/node-ops.md` (power operations), `services/kubeletto/README.md`.
