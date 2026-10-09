# AGENTS.md

Infrastructure-as-code for a single-operator homelab: a MikroTik hEX router, a
TP-Link SG108E switch, a Proxmox cluster (`homelab`) and, later, a VPS front.
The repo is the source of truth; the live hardware is converged to it.
Read `docs/design/network-design.md` before changing anything network-facing.

## Who owns what

| Layer | Tool | Where |
| --- | --- | --- |
| Addresses, VMIDs, placement (single source) | YAML, validated by a Tofu module | `inventory/lab.yaml` |
| Router (hEX, RouterOS 7) | OpenTofu, `terraform-routeros/routeros` | `network/routeros/` |
| Proxmox guests (LXC/VM) | OpenTofu, `bpg/proxmox` | `proxmox/opentofu/` |
| Proxmox hosts (pve2, pve3) | Ansible, one playbook, tagged | `ansible/proxmox-nodes.yml` |
| Switch | no provider — config backup + runbook | `network/switch/` |
| In-guest setup | scripts run by Tofu provisioners | `services/<name>/` |

Addresses, VMIDs and node placement are changed in `inventory/lab.yaml` only
(ADR 0007); an IP typed into a `.tf` file is a review finding. New LXC
guests use `proxmox/opentofu/modules/lxc-guest`.

Change the code, then converge. A hand edit on a router, host or guest is
**drift**; when a one-off manual step is unavoidable (a disk format, a package
purge), record it in the commit body and the relevant runbook.

## Reaching the lab

The operator Mac reaches everything over Tailscale via `admin-gw` (CT 101 on
pve3). SSH is key-based.

| Target | Address |
| --- | --- |
| pve2 / pve3 (SSH `root@`, UI `:8006`) | `10.10.10.12` / `10.10.10.13` |
| hEX REST (what Tofu uses) | `https://192.168.99.1/rest/<path>` |
| hEX SSH / WinBox | `10.10.10.1` (port 22 / 8291) |
| Switch UI | `http://192.168.99.2` |
| Out-of-band recovery port (hEX ether3) | `192.168.88.1` |

VLANs and static IPs: `docs/design/network-design.md` §2.

## Commands

```bash
# Toolchain: pinned in mise.toml (same versions in CI). Once per machine:
mise install
make check   # static: tofu fmt/validate, tflint, shellcheck, yamllint,
             # ansible-lint, promtool/amtool, gitleaks — CI runs exactly this
make drift   # both tofu plans + Ansible --check (needs the age key + lab)

# OpenTofu — secrets come from SOPS, decrypted into the process env only
cd network/routeros   # or proxmox/opentofu
tofu init
sops exec-env secrets.sops.env 'tofu plan'
sops exec-env secrets.sops.env 'tofu apply'

# Ansible — always pipe the output (it aborts with "non-blocking IO" in
# agent shells otherwise)
cd ansible
ansible-playbook proxmox-nodes.yml --check --diff | cat   # drift report
ansible-playbook proxmox-nodes.yml --tags storage | cat   # converge one area
ansible-playbook proxmox-nodes.yml --limit pve3 | cat
# tags: repos, logind, grub, network, ssh, gpu, storage, monitoring, verify,
#       upgrade (explicit only), cluster (explicit only)

./scripts/hex-snapshot.sh   # router config export → network/routeros/snapshots/
```

The RouterOS provider prints "field was lost during the Schema development"
warnings on every plan; they are noise. Only the `Plan:` / `No changes` line
matters.

## Workflow for any change

1. **Read the live state first**: `tofu plan`, `ansible --check --diff`, or
   read-only `GET`/`ssh` commands. Start from zero drift.
2. **Router changes**: snapshot before and after (`./scripts/hex-snapshot.sh`),
   and commit both. Keep SSH, `www-ssl` and WinBox working — those are the
   management path. ether3 is the fallback if access breaks.
3. Change the code, review the plan or diff, apply.
4. **Verify against reality.** Done means `No changes` from both Tofu stacks,
   `changed=0 failed=0` from a full Ansible `--check`, and the live effect
   observed directly (the effective value, a test run, a real restore).
   Anything that must survive a boot is proven by a **cold reboot**: live
   checks once missed a `/dev/nvidia-uvm` that only existed because a CUDA
   app had already run during that boot.
5. `make check` passes (CI runs it on every push; the pre-commit hook scans
   the staged diff for secrets).
6. Update the docs the change touches (below), then commit that piece alone.
   The commit body says what was wrong, why, and how it was verified. Pushing
   is the operator's call.

## Cluster and node rules

- **Two-node quorum.** With either node down, the cluster is non-quorate:
  guests keep running, but management actions lock. Reboot one node at a time
  and wait for `pvecm status` → `Quorate: Yes` before touching the other.
  Agents may reboot nodes themselves as part of ongoing work, on those terms.
- pve3 hosts `admin-gw`, the remote-access path. It comes back by itself
  after a reboot; confirm it with `pct list`.
- **Placement**: stateful guests (databases, monitoring data, PBS primary) go
  on pve2. pve3 has a no-name SSD and gets only stateless or rebuildable
  guests. pve1 (desktop, RTX 3060) is not built yet and will run on demand,
  never always-on services.
- Unattended apt on hosts: pass `-o Dpkg::Options::=--force-confold`. Some
  conffiles carry local config (`/etc/dkms/framework.conf`), and a conffile
  prompt aborts non-interactive runs.
- Root-only Proxmox config (`devN:` passthrough, `lxc.idmap`) cannot be set
  with the API token. Use the pattern in `proxmox/opentofu/admin-gw.tf`: an
  idempotent root script over SSH via `terraform_data`, with
  `ignore_changes` on the attribute.
- DHCP runs only on VLANs 30/40/50. Guests on 10, 20 and 25 need a static IP
  (design §2).

## Secrets

SOPS + age: one age key on the operator Mac decrypts every `*.sops.env`.
OpenTofu state is encrypted (`encryption.tf`, `enforced = true`) and
committed. The pre-commit hook (`.githooks/pre-commit`, enabled with
`git config core.hooksPath .githooks`) refuses plaintext state, unencrypted
`*.sops.*` files and `.env` files. Handle values without printing them:
compare in code and report match/mismatch, lengths or key names only.
Procedures (edit, rotate, recover): `docs/runbooks/secrets.md`.

## Docs

| Kind | Where | Rule |
| --- | --- | --- |
| Why a choice was made | `docs/decisions/NNNN-*.md` + index | Accepted ADRs are never edited; supersede with a new one |
| How to do a procedure | `docs/runbooks/` | Update when the procedure changes |
| Measurements / trials | `docs/experiments/` | |
| What broke and why (RCA) | `docs/incidents/YYYY-MM-DD-*.md` | Timeline, evidence, action items; link the fix commits |
| What the hardware is | `docs/hardware.md` | Update when a part changes |
| What is done / next | `README.md` → Status | Keep it current |

Reach for the runbook before acting on its area: GPU passthrough to LXC
(`gpu-lxc-passthrough.md`), Secure Boot/DKMS signing (`secure-boot-mok.md`),
cluster join/recovery (`proxmox-cluster.md`), node install
(`proxmox-install.md`), power operations (`node-ops.md`), router/switch
bootstrap (`hex-bootstrap.md`, `switch-bootstrap.md`).

## Working with the operator

- "Advise" means audit read-only and recommend one option with reasons.
  "Proceed" or "do your best" means execute end to end.
- Physical and account-level steps belong to the operator: BIOS settings,
  plugging in disks, Tailscale logins, 2FA enrollment. Give exact
  click-by-click steps, then verify remotely.
- Destructive steps need an explicit yes, after you have looked at the
  target: formatting a disk, deleting a guest or its volume, firewall
  changes that could cut the management path.
