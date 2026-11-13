#!/usr/bin/env python3
"""Backup freshness for Prometheus (node_exporter textfile collector).

Installed on ONE Proxmox node by ansible/proxmox-nodes.yml (tag: monitoring),
run by a systemd timer every 10 minutes. Writes backup.prom next to the SMART
and thin-pool collectors; alerts: services/monitoring/prometheus/rules/backups.yml.

What it answers: "for every guest a backup job is meant to cover, when did that
job last leave a good snapshot in the backup storage?" Nothing is listed by
hand. The expected set comes from the cluster's own backup jobs
(`pvesh get /cluster/backup`: `all` minus `exclude`, or the `vmid` list) and the
live guest list (`/cluster/resources`), so a deleted guest or a changed
exclusion simply stops being expected. The snapshots come from each job's
storage (`/nodes/<node>/storage/<storage>/content`).

Series, one per (guest, job, storage):
  homelab_backup_expected                         1
  homelab_backup_snapshots                        good snapshots in the storage
  homelab_backup_last_success_timestamp_seconds   newest good snapshot; while a
        guest has none, the time it was first seen as expected, so a new guest
        gets one full alert window for its first backup and a guest that is
        never backed up alerts exactly like one that went stale.
A snapshot whose PBS verification failed is not a good snapshot.

Failure of any pvesh call: exit 1 and leave the file alone. Its mtime then goes
stale (HostTextfileCollectorStale) and the unit shows failed
(HostSystemdUnitFailed); a half-written view would raise false alerts.

Usage: backup-freshness.py [--out FILE|-] [--state FILE]
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

DEFAULT_OUT = "/var/lib/prometheus/node-exporter/backup.prom"
DEFAULT_STATE = "/var/lib/prometheus/backup-freshness-state.json"


def pvesh(*args):
    out = subprocess.run(
        ["pvesh", "get", *args, "--output-format", "json"],
        check=True, capture_output=True, text=True, timeout=120,
    ).stdout
    return json.loads(out)


def csv(value):
    return {int(v) for v in str(value or "").replace(" ", "").split(",") if v}


def expected_guests(jobs, guests):
    """[(vmid, name, job id, storage)] every enabled vzdump job must cover."""
    by_id = {g["vmid"]: g for g in guests if not g.get("template")}
    rows = []
    for job in jobs:
        if job.get("type") != "vzdump" or not job.get("enabled", 1):
            continue
        if job.get("all"):
            vmids = set(by_id) - csv(job.get("exclude"))
            if job.get("node"):
                vmids = {v for v in vmids if by_id[v].get("node") == job["node"]}
        elif job.get("vmid"):
            vmids = csv(job["vmid"]) & set(by_id)
        else:
            # pool jobs are not used in this lab; refuse to guess
            raise SystemExit(f"job {job['id']}: neither all nor vmid (pool?) is not supported")
        for v in sorted(vmids):
            rows.append((v, by_id[v].get("name", f"vmid-{v}"), job["id"], job["storage"]))
    return rows


def good_snapshots(entries):
    """vmid -> sorted ctimes of snapshots that did not fail verification."""
    out = {}
    for e in entries:
        if (e.get("verification") or {}).get("state") == "failed":
            continue
        out.setdefault(int(e["vmid"]), []).append(int(e["ctime"]))
    return {v: sorted(t) for v, t in out.items()}


def render(rows, snaps, first_seen, now):
    lines = [
        "# HELP homelab_backup_expected A guest a backup job is meant to cover (1).",
        "# TYPE homelab_backup_expected gauge",
        "# HELP homelab_backup_snapshots Good snapshots of the guest in the job's storage.",
        "# TYPE homelab_backup_snapshots gauge",
        "# HELP homelab_backup_last_success_timestamp_seconds Newest good snapshot (first-seen time while there is none).",
        "# TYPE homelab_backup_last_success_timestamp_seconds gauge",
    ]
    state = {}
    for vmid, name, job, storage in rows:
        key = f"{vmid}:{storage}"
        times = snaps.get(storage, {}).get(vmid, [])
        state[key] = first_seen.get(key, now)
        last = times[-1] if times else state[key]
        lab = f'vmid="{vmid}",name="{name}",backup_job="{job}",storage="{storage}"'
        lines.append(f"homelab_backup_expected{{{lab}}} 1")
        lines.append(f"homelab_backup_snapshots{{{lab}}} {len(times)}")
        lines.append(f"homelab_backup_last_success_timestamp_seconds{{{lab}}} {last}")
    return "\n".join(lines) + "\n", state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--state", default=DEFAULT_STATE)
    args = ap.parse_args()

    now = int(time.time())
    node = socket.gethostname().split(".")[0]
    try:
        jobs = pvesh("/cluster/backup")
        guests = pvesh("/cluster/resources", "--type", "vm")
        rows = expected_guests(jobs, guests)
        snaps = {}
        for storage in sorted({r[3] for r in rows}):
            snaps[storage] = good_snapshots(
                pvesh(f"/nodes/{node}/storage/{storage}/content", "--content", "backup"))
    except (subprocess.SubprocessError, OSError, ValueError) as err:
        print(f"backup-freshness: {err}", file=sys.stderr)
        return 1

    try:
        with open(args.state) as f:
            first_seen = json.load(f)
    except (OSError, ValueError):
        first_seen = {}
    text, state = render(rows, snaps, first_seen, now)

    if args.out == "-":
        sys.stdout.write(text)
        return 0
    tmp = args.out + ".tmp"  # not *.prom: node_exporter ignores it
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, args.out)
    stmp = args.state + ".tmp"
    with open(stmp, "w") as f:
        json.dump(state, f)
    os.replace(stmp, args.state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
