# SG108E — TP-Link 8-port managed switch

No usable IaC provider exists for this switch, so it is configured through its
web UI and the **exported backups in git are the source of record**.

## Rules

- Export a config backup after every change (`System → Backup/Export` in the
  switch UI) → `backups/sg108e-<date>.cfg`.
- The port/VLAN plan lives in
  [`../../docs/design/network-design.md`](../../docs/design/network-design.md) (section 3).
- Build-time management: `192.168.99.2/29`, gateway `192.168.99.1`.
