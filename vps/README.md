# VPS — public front (later)

The rented VPS that fronts public services (HAProxy L4 + WireGuard), per the
design. No inbound ports at home.

Planned:

- OpenTofu for provisioning (provider + cloud-init).
- Ansible / hardening + HAProxy and WireGuard config.
- DNS records.
