# logs — VictoriaLogs, the lab's log store

Every node, container and the hEX send their logs here: CT 121 `logs` on
pve2 (`10.10.10.18`, VLAN 10). Why this store and this layout:
[ADR 0008](../../docs/decisions/0008-observability-standard.md). The standard
apps follow: [docs/standards/observability.md](../../docs/standards/observability.md).

| | |
| --- | --- |
| Query | Grafana → Explore → **VictoriaLogs**, or the Service dashboard's Logs panel. Built-in UI: `http://10.10.10.18:9428/select/vmui` (MGMT/TRUSTED/admin-gw only, no login) |
| Retention | 30 days, hard cap 6 GiB (10 GB disk). At the cap the oldest days go first (`LogsNearDiskCap`, info) |
| Built by | `proxmox/opentofu/logs.tf` → `setup.sh` (pinned release + sha256) |
| Version | `VL_VERSION` in `setup.sh` (community release from GitHub, tarball checksum pinned) |

## How logs arrive

| Sender | How | Configured by |
| --- | --- | --- |
| Containers with `logs: true` in `lab.yaml` | `systemd-journal-upload` → `http://10.10.10.18:9428/insert/journald` | `ship.sh`, run by `terraform_data.log_shipping` |
| pve2, pve3 | the same | Ansible `--tags logging` |
| hEX | BSD syslog over UDP → `:5514` (RouterOS sends this format over UDP only) | `network/routeros/logging.tf` |

journal-upload keeps a cursor: after an outage of the store it resumes where
it stopped, with the sender's own journal as the buffer (tested 2026-10-10:
CT 121 stopped for a minute, pve3's uploader kept retrying without hitting
systemd's start limit, and the line logged during the outage arrived 40 s
after the store came back; idle senders recovered on their own). On first start it
sends the whole local journal. Lines older than the 30-day retention are
dropped at ingest (`vl_rows_dropped_total{reason="too_small_timestamp"}`),
which is expected.

Senders outside VLAN 10 need the hEX to let them in: one exact rule per host
(`forward_logs_ingest`), generated from `logs: true`. The DMZ never ships into
MGMT; `lab.yaml` refuses `logs: true` there.

## Fields worth knowing

| Source | Stream fields | Useful fields |
| --- | --- | --- |
| journald | `_MACHINE_ID`, `_HOSTNAME`, `_SYSTEMD_UNIT` | `_msg`, `level` (from `PRIORITY`), `SYSLOG_IDENTIFIER`, `_PID` |
| syslog (hEX) | `hostname` (`hex-lab`, the router identity), `app_name` | `_msg`, `level`, `facility_keyword` |

`_HOSTNAME` is the inventory name for every node and container (the module
sets the hostname). The hEX reports its identity, `hex-lab`, not `hex`.

## Queries (LogsQL)

```text
_stream:{_HOSTNAME="pve2"}                         # one host
_stream:{_HOSTNAME="archive", _SYSTEMD_UNIT="filebrowser.service"}
_stream:{hostname="hex-lab"} error                 # router, word "error"
_time:1h level:err                                 # every error in the last hour
* | stats by (_HOSTNAME) count() hits | sort by (hits desc)   # who logs most
"exact phrase"                                     # quote anything with - or :
```

## Changing things

- **Any file here** → `tofu apply` in `proxmox/opentofu`: it re-streams this
  directory and re-runs `setup.sh` (keyed on the files' hashes). `ship.sh`
  changes re-run on every shipping container.
- **A new container that ships logs:** `logs: true` in its `lab.yaml` block,
  and its recreation marker in `local.guest_generation` (`logs.tf`); the plan
  fails until it is there.
- **The archive CT ships too** (`log_shipping["archive"]`), but it stays
  stopped after a pve2 reboot until the operator remounts its disks
  (`services/archive/README.md`). In that window, a `tofu apply` that
  re-runs shipping (any `ship.sh` edit) fails on `pct exec 110`: remount
  first, or apply with `-target` around it.
- **Upgrade:** bump `VL_VERSION` and `VL_SHA256` (from the release's
  `victoria-logs-linux-amd64-<ver>_checksums.txt`), apply.

## Gotchas found while building

- LogsQL reads `-` and `:` as operators: `observability-standard` is not a
  word search. Quote it.
- A bare word searches the message (`_msg`) only. `logger -t mytag hello`
  is found by `hello`, not by `mytag`; use `SYSLOG_IDENTIFIER:mytag`.
- `-syslog.streamFields.udp` is an array flag. It prints oddly in the
  startup log, but it works: `proc_id` is stored and not part of the stream.
- Installing `systemd-journal-remote` (for the uploader) also ships a
  receiver on port 19532. `ship.sh` and Ansible mask it.
