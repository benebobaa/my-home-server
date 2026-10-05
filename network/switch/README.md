# SG108E — TP-Link 8-port managed switch

No usable IaC provider exists for this switch, so it is configured through its
web UI and the **exported backups in git are the source of record**.

## Rules

- Export a config backup after every change (`System → Backup/Restore` in the
  switch UI) → `backups/sg108e-<date>.cfg` (first: `sg108e-2026-10-06.cfg`).
- The port/VLAN plan lives in
  [`../../docs/design/network-design.md`](../../docs/design/network-design.md) (section 3).
- Management: `http://192.168.99.2` — directly from P1 (VLAN 1), or from the
  management/trusted VLANs through the hEX (`forward_switch_mgmt` rule).
- Setup procedure: [`../../docs/runbooks/switch-bootstrap.md`](../../docs/runbooks/switch-bootstrap.md).
