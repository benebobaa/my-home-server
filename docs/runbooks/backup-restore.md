# Backup and restore (PBS)

Every guest is backed up nightly at 02:30 to PBS (CT 111 on pve3, storage
`pbs`). Why and what is not covered (bind mounts — the family archive):
[ADR 0009](../decisions/0009-backups-pbs-on-pve3.md). Service:
[`services/pbs/`](../../services/pbs/README.md).

Run commands on a node as root (`ssh root@10.10.10.12` or `.13`).

## See what exists

```bash
pvesm list pbs                       # every backup: volid, size, VMID
pvesm list pbs --vmid 120            # one guest
pvesm status --storage pbs           # storage active? how full?
pvesh get /cluster/backup/nightly    # the job
```

The PVE UI shows the same under Datacenter → Storage `pbs` → Backups, with
a **Restore** button and **File Restore** for single files.

## Back up now

```bash
vzdump <vmid> --storage pbs --mode snapshot        # one guest, on its node
vzdump --all 1 --exclude 111 --storage pbs --mode snapshot   # all guests on this node
```

## Restore a whole guest — test first, then for real

**Test restore (no risk to the live guest)** — what was done on 2026-10-10:

```bash
# on pve3 (more free thin pool than pve2)
vol=$(pvesm list pbs --vmid 120 | awk 'NR>1 {print $1}' | tail -1)   # newest
pct restore 9120 "$vol" --storage local-lvm --unique 1    # new VMID, new MAC
pct set 9120 --delete net0 --onboot 0 --hostname restore-test   # no IP clash
pct start 9120
pct exec 9120 -- curl -s '127.0.0.1:9090/api/v1/query?query=count(up)'   # data there?
pct stop 9120 && pct destroy 9120 --purge 1
```

Result then: 3.7 GiB in 45 s; Prometheus answered from data written before
the backup (26 targets at 05:30Z, pve3's boot at 22:23:54Z).

**Test restore of the K3s server, VM 300** (Kubeletto's cluster state and
secrets), done 2026-10-15 on pve2 (the only node with the thin-pool room):

```bash
vol=$(pvesm list pbs --vmid 300 | awk 'NR>1 {print $1}' | tail -1)
qmrestore "$vol" 9300 --storage local-lvm --unique 1
qm set 9300 --delete net0 --memory 1536 --balloon 0 --onboot 0 --name restore-drill-300
qm start 9300
# K3s refuses to start without a default route ("no default routes found"):
# give the NIC-less copy a black hole with VM 300's address, then run the
# server alone (with the kubelet, 1.5 GB thrashes: every platform pod starts)
qm guest exec 9300 -- sh -c 'ip link add dummy0 type dummy; ip addr add 10.10.25.20/24 dev dummy0;
  ip link set dummy0 up; ip route add default via 10.10.25.1 dev dummy0;
  systemctl stop k3s; /usr/local/bin/k3s-killall.sh;
  systemd-run --unit=k3s-drill /usr/local/bin/k3s server --disable-agent'
qm guest exec 9300 -- sh -c 'k3s kubectl get --raw /readyz; k3s kubectl -n platform get secret platform-core-env -o go-template="{{len .data}}"'
qm stop 9300 && qm destroy 9300 --purge 1 --destroy-unreferenced-disks 1
```

Result: 40 GB (81 % zeros) in 106 s; `readyz ok`; the backup of 2026-10-14
02:32 WIB had 189 tenant namespaces, 45 Knative services, 22 Secrets, and the
encrypted Secrets decrypted (platform-core-env: 61 keys; nats-auth, R2,
TLS), so the encryption key travels with the backup. Never give the copy a
real NIC: it would be a second control plane with the same address and the
tunnel's credentials.

**Real restore (the guest is broken or gone):**

1. Stop the broken guest: `pct stop <vmid>`.
2. Restore over it: `pct restore <vmid> <volid> --storage local-lvm --force 1`
   (on the node it should run on; `--force` replaces the existing disk).
3. `pct start <vmid>`; check its service and the Service dashboard.
4. Converge: `tofu plan` in `proxmox/opentofu` should be `No changes`. If
   setup steps are keyed on the container's MAC (`generation`), a restore
   with `--unique 0` keeps the MAC and nothing re-runs.

A guest that is easier rebuilt than restored (admin-gw, logs) can also just
be rebuilt with `tofu apply` (`-replace` on its module); its data is then
the backup's to restore if needed.

## Restore one app's database

Postgres (CT 130) also keeps a nightly logical dump per database on its disk,
which restores one app without touching the others:
[services/postgres → Backups and restore](../../services/postgres/README.md#backups-and-restore).

## Restore single files

PVE UI → storage `pbs` → pick the backup → **File Restore** → browse and
download. CLI equivalent from inside the PBS CT:

```bash
pct exec 111 -- proxmox-backup-client catalog dump <snapshot> --repository 'pve@pbs!cluster@localhost:main'
```

(needs the token secret; the UI is simpler.)

## If PBS itself is gone

The backups are on CT 111's root disk on pve3. Rebuild the CT with
`tofu apply` only if the volume is lost anyway; otherwise restore the CT's
disk first. The datastore survives a CT rebuild only if its volume is kept.
After a rebuild, `terraform_data.pbs_link` recreates the token and storage
entry.

## When it fails

- **Nightly job failed** → Telegram (PVE notification). Read the task log:
  PVE UI → node → Tasks, or `journalctl -u pvescheduler`.
- **Verify/GC/prune failed** → Telegram (PBS notification). In the CT:
  `proxmox-backup-manager task list`.
- **`PveGuestNotBackedUp`** → a guest is outside the job: see
  [alerts.md](alerts.md#pveguestnotbackedup).
