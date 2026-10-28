# 0021 — Kubeletto's registry keeps its blobs on the K3s server's own disk

**Status:** accepted (2026-10-28). The operator wants everything
self-hosted that can be. Supersedes the "the registry stays on R2" line of
[ADR 0004](0004-public-ingress-cloudflare-tunnel.md) and
[ADR 0011](0011-kubeletto-on-the-home-cluster.md).

## Context

Kubeletto's registry (Distribution 2.8.3, in-cluster, token auth from core)
stored its blobs in the R2 bucket `kubeletto-registry`: 6,842 objects, 7.7 GiB
on 2026-10-28. R2 costs nothing at that size (free tier 10 GB), so the move
saves no money; the reasons are dependency and control: one less cloud
account, one less credential on a host, the storage path as short as the rest
of the platform. Pulls and pushes already use the in-cluster Service
(`registries.yaml` mirrors `registry.kubeletto.com` to its ClusterIP), so
streaming blobs through the registry pod instead of redirecting clients to R2
changes no external path (no tunnel, no 50 Mbps DMZ cap).

## Decision

- VM 300 gets a second disk (`scsi1`, 40 GB, `local-lvm` on pve2,
  `backup = false`), formatted ext4 (label `registry`) and mounted at
  `/mnt/registry` by `services/k3s/registry-disk.sh` (idempotent, refuses a
  disk that carries anything else; OpenTofu `terraform_data.k3s_registry_disk`).
- The registry mounts `/mnt/registry/data` (hostPath, type `Directory`, so an
  unmounted disk leaves the pod Pending instead of filling the root disk) and
  uses the `filesystem` storage driver. It runs on the server node already
  (placement patch). `Recreate`, not `RollingUpdate`: one directory, one writer.
  The change is a home-only patch in the Kubeletto repo
  (`infra/k8s/home/registry-config-patch.yaml`, `registry-storage-patch.yaml`).
- The S3 layout is the filesystem layout, so the migration is a copy
  (`services/kubeletto/registry-copy.sh`, an rclone Job using the registry's own
  R2 secret); digests are unchanged. R2 stays a week as the rollback.

## Consequences

- **The registry volume has no backup.** The PBS datastore has about 5 GB free
  and cannot hold it; the disk is excluded like the family archive. About 22 of
  the 52 restored services are built from source: if pve2's SSD is lost their
  images exist nowhere until the owners redeploy, and `restore.sh` cannot
  bring them back (it redeploys stored images). The other ~30 run public images
  that pull again. The operator accepted this trade-off for self-hosting.
  A second copy (an rsync to pve3 or an external disk) is the next step if
  that stops being acceptable.
- The registry's disk usage needs watching (the node-exporter filesystem
  alerts on VM 300 cover the mount). Retention and garbage collection are still
  off at home (dry run: `docs/experiments/2026-10-15-registry-retention-dry-run.md`);
  with local storage `registry garbage-collect` is fast and local when wanted.
- The registry no longer needs R2 credentials. `kubeletto-registry` is
  deleted after the rollback week; `kubeletto-builds` and `kubeletto-releases`
  stay on R2.
