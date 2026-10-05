# 0001 — OpenTofu for RouterOS config

**Status:** accepted (2026-10-05)

## Context

Configuring the MikroTik hEX by hand is error-prone and invisible to review.
The router config should live in git, with a plan step before anything is
applied.

Options considered:

- **Terraform** (installed, v1.5.7): mature, but old version and BUSL-licensed.
- **OpenTofu**: drop-in, open-source (Linux Foundation), actively released.
- **Ansible** (`community.routeros`): procedural; no state/plan/diff model.
- **Raw `/import` scripts**: simple, but no diff, no plan, no drift detection.

## Decision

Use **OpenTofu** with the community provider
[`terraform-routeros/routeros`](https://github.com/terraform-routeros/terraform-provider-routeros)
over the RouterOS REST API (self-signed TLS → `insecure = true`).

The provider covers everything needed here: interfaces/VLANs, addresses, DHCP,
firewall (filter/NAT/mangle), address lists, DNS, users, services.

## Consequences

- Router changes go `tofu plan → review → apply`; state stays local and
  git-ignored (it may contain secrets).
- A tiny hand-applied bootstrap remains: user, OOB IP, REST API cert
  (`network/routeros/bootstrap.rsc`). Everything else is code.
- Provider is pinned to the resolved minor (`~> 1.99`) via the lock file.
- Ansible stays an option for host-level config of the VPS/guests later.
