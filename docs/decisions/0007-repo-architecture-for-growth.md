# 0007 — Repo architecture for growth: one inventory, an LXC module, Ansible for guest config

**Status:** accepted (2026-10-09)

## Context

The repo manages the whole lab and is expected to grow: pve1, PBS, Postgres,
K3s for Kubeletto, more services. The foundation already works: one owner
per layer, ADRs and runbooks, SOPS secrets, encrypted state, a secret-guarding
hook, and the "zero drift, then cold reboot" rule. An audit (2026-10-09) found
three things that would not scale:

1. **Addresses lived everywhere.** Host IPs appeared in 12 code files across
   Tofu, Ansible and Prometheus, plus 14 docs. Adding the monitoring CT
   touched six code files in three tools.
2. **Every container was hand-copied.** admin-gw, archive and monitoring
   repeat the same container block, root-only step and secret delivery, each
   with small differences. Two flaws were copied along with them:
   - **Re-run on any change.** `replace_triggered_by` on the whole container
     re-runs setup steps on any in-place change. A stopped container
     (`started` flipping) was enough.
   - **Blanked output.** The SSH key *path* was marked sensitive, which
     hid every provisioner's output.
3. **Drift inside guests was invisible.** "Done" means zero drift from Tofu
   and Ansible, but in-guest config is applied by shell scripts that re-run
   only when a repo file changes. A hand edit inside a CT goes unseen.

There was also no linting, no CI and no pinned toolchain (fixed separately:
`mise.toml`, `make check`, `.github/workflows/check.yml`).

## Decision

1. **`inventory/lab.yaml` is the one source of host addresses.** It holds VLANs
   (id, CIDR, gateway) and every host: devices, nodes, guests and reserved
   addresses. It also records the VMID and IP conventions. `inventory/` is a
   provider-less Tofu module. It loads the file, validates it (unique IPs
   and VMIDs, each IP inside its VLAN) and outputs ready-made maps.
   - **Consumers today:** both Tofu stacks (DNS records, firewall address
     lists, SNMP, guest network config, SSH targets).
   - **Next:** the Ansible inventory and the Prometheus targets, each in its
     own change.
   - **Check:** `make check` evaluates the validation without secrets.
2. **`proxmox/opentofu/modules/lxc-guest`** owns the container and nothing
   else: network from the inventory, sizes, boot flags, and the template.
   - Provisioning stays in each service's `.tf` file, because it really
     differs per service.
   - The module outputs a `generation` value (the container's MAC address,
     which PVE generates at creation). Setup steps key on it, so they re-run
     when the container is **recreated**, not when it is merely updated.
   - Existing containers moved in with `moved` blocks (no rebuild).
   - The archive CT stays as it is until it is rebuilt on ZFS: its
     hand-mounted sources make re-running its steps unsafe today.
3. **Configuration inside guests moves to Ansible roles, gradually.** The same tool
   as the hosts, with `--check --diff` drift reports for guests. New guests
   start that way. Existing ones move over when they are next changed
   substantially. Tofu creates, Ansible configures.
4. **Apps on K3s (Kubeletto) will be GitOps** (Flux), in `k8s/` or a separate
   repo, not Tofu or Ansible.

Not adopted, each for a reason:

| Not adopted | Why |
| --- | --- |
| Terragrunt | Two stacks, one operator |
| A remote state backend | No concurrency to solve; one apply at a time |
| A staging environment | Snapshots, plan review and small blast radius are the homelab equivalent |
| Splitting into several repos | One lab, one operator |
| NetBox | A YAML file is enough until roughly 50 hosts |

## Consequences

- **A new guest needs** one entry in `lab.yaml`, a `module "lxc-guest"`
  block, and its `services/<name>/` directory. DNS and addresses follow
  from the inventory.
- **Address changes go through `lab.yaml`.** An IP typed into a `.tf` file
  is a review finding.
- **admin-gw's rebuild path still runs through itself.** All provisioning
  goes through it: the Mac reaches pve3 via its subnet route. Rebuilding
  admin-gw needs the P7 cable, or the second subnet router that is still
  open in design §9. The module does not change this.
- The archive keeps its hand-written resources until its ZFS rebuild.
- Docs keep describing *why*. The address table in design §2 now points to
  `lab.yaml` instead of repeating it.
