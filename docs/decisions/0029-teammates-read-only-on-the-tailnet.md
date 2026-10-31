# 0029 — A teammate reads an app's database over the tailnet, read-only

**Status:** accepted (2026-10-31). Asked for by the operator: a member of
larasrouter's team should be able to read its database. Amends the
"reaching it" table of the app standard ([ADR 0010](0010-shared-postgres-and-app-standard.md)):
people other than the operator and family can now be on the tailnet, under a
policy that limits each of them to one port.

## Context

larasrouter has been in production since 2026-10-29. Its database is in the
shared Postgres (CT 130, ADR 0022) and its cache in the shared Valkey (CT 132).
The operator reaches both through root SSH on the nodes (`connect.sh`,
`tunnel.py`); that path cannot be shared without sharing root on the cluster.

Three findings shaped the decision:

- **The tailnet ran the default policy** (everyone reaches everything), and the
  admin gateways route the management VLAN, the switch and recovery port, and
  the `ai` VM. Inviting anyone under it gives their device network reach to the
  Proxmox UIs and SSH, the hEX, the switch's plain-HTTP UI, `archive`, the
  operator's own devices and the Kubeletto admin plane.
- **Valkey has a single password**, and larasrouter returns a cached session
  without asking the database (larasrouter `internal/auth/service.go`, `Authenticate`). Whoever
  holds that password can write a session for any user, and change the cached
  exchange rate, fee and balances. No person gets it.
- **Not every column is safe to read.** `email_outbox.payload` holds the raw
  password-reset URL (the only place the unhashed token is written) and the
  verification URL. Reading it is taking over any account with a pending reset.
  Passwords and every other token are stored as hashes.

## Decision

- **Postgres, read-only, per person.** A NOLOGIN group `<db>_read` with
  CONNECT, USAGE on `public` and SELECT on every column of every table except
  the hidden ones, granted column by column (`services/postgres/readers.sh`, declared as
  `postgres_readers` in `postgres.tf`). Hidden for larasrouter:
  `users.password_hash`, `email_outbox.payload`, and the four token and key hashes.
  One login role per person, `<db>_<handle>`, in that group, with an
  OpenTofu-generated password. The grants are the control; the role's settings
  (read-only transactions, 60 s statement and idle-in-transaction timeouts,
  5 connections) are a seatbelt. A person removed from the list loses LOGIN and
  their sessions.
- **It fails closed.** No table-level grant and no default privileges: a
  table or column that a migration adds later is unreadable until
  `readers.sh` runs again, after the operator has checked it for secrets
  (an LLM router may well store provider keys one day). `migrate.sh` prints
  the reminder. The cost is one targeted `tofu apply` after a release that
  adds columns; until then `SELECT *` fails on the changed tables. An
  automated security review of the first version, which made new tables
  readable by default privileges, asked for this.
- **No Valkey access for people.** A read-only Valkey user (`+@read -@dangerous`)
  is a possible later change to `instances.sh`, with its own reason.
- **Reachability: the tailnet, under a written policy.**
  `network/tailscale/policy.hujson` replaces the default policy: the operator
  keeps everything, shared-in users keep the shared machine, and
  `group:larasrouter-readers` reaches `10.10.20.21:5432` and nothing else.
  The admin gateways advertise `10.10.20.21/32`; the hEX already forwards
  the gateways into VLAN 20. Postgres admits `+larasrouter_read` from the two
  gateway addresses only (they SNAT), so a reader needs both a tailnet grant
  and a reader password.
- **The repo is public:** logins live in `network/tailscale/identities.sops.env`;
  `render-policy.sh` fills them in and the operator pastes the result in the
  admin console. Postgres handles are not names. The policy's `tests` block
  makes the console refuse a policy that would let a reader reach the
  management plane.
- `setup.sh` now reloads Postgres instead of restarting it when nothing read at
  server start has changed (a `pg_hba` change drops no session), and fails if
  `pg_hba.conf` does not parse.

## Consequences

- A teammate's laptop is on the tailnet. What it can reach is one Postgres
  port, enforced by the gateways (Tailscale filters subnet traffic at the
  router), then `pg_hba`, then the grants.
- The read path loads the shared CT 130. The connection limit and timeouts cap
  that; a long query from a GUI can still compete with Kubeletto and
  larasrouter for the 100 connections and the CPU.
- GUI table browsers run `SELECT *`, which fails on the tables with hidden
  columns (and, until the grants are refreshed, on tables a release changed) (`users`, `email_outbox`, `sessions`, `api_keys`,
  `password_reset_tokens`, `email_verification_tokens`): name the columns.
- **Reader logins are not logged** (`log_connections` is off; turning it on is
  a config change, so a restart). Without it there is no record of who
  read what, or when.
- The tailnet policy now exists: the open item in the design (§ Remote admin)
  and the `tag:admin` restriction ADR 0027 asked for are covered by it.
- The operator's Mac also gets the route to `10.10.20.21`, but the operator's
  own role `larasrouter` is still refused from the gateways: `connect.sh`
  stays the operator's path.

## Rollout

Done 2026-10-31 by OpenTofu (targeted; the stack has unrelated drift):
`readers.sh` and the `pg_hba` lines live, Postgres reloaded, not restarted;
both gateways advertise `10.10.20.21/32`.

Operator steps (Tailscale admin console):
1. Approve `10.10.20.21/32` on `admin-gw` and `admin-gw2` (Machines → … → Edit route settings).
2. From the home LAN: copy the current policy out (rollback). If it has
   anything besides the default `grants`/`acls`, `ssh`, `nodeAttrs` and the
   `tag:admin` owner, carry it into `policy.hujson` first.
3. `sops network/tailscale/identities.sops.env`: set the teammate's login in
   `LARASROUTER_READERS` (`reader1=<login>`). Then
   `network/tailscale/render-policy.sh | pbcopy`, paste, save.
4. Check: the Proxmox UI from the Mac; Irene opens the archive.
5. Invite the teammate (Users → Invite users). Send them
   `services/larasrouter/urls.sh reader larasrouter_reader1` over a private channel.
6. From their machine: a `SELECT` works, `https://10.10.10.12:8006` times out.

## Verification

2026-10-31, as `larasrouter_reader1` on CT 130's loopback: `SELECT *` on tables
without hidden columns and `SELECT` of visible columns work (248 column grants
= 254 columns less the 6 hidden; no table-level grant, no default ACL); the six hidden columns, `SELECT *` on
their tables, `INSERT` (with read-only switched off) and `CREATE` are refused.
`pg_hba_file_rules` has no error and the two new lines admit `+larasrouter_read`
from `10.10.10.15` and `10.10.10.17` only; the server logged the SIGHUP
reload, and its start time is unchanged (reload, not restart). Both gateways
advertise the route and open 10.10.20.21:5432 through the hEX; management
access over the tailnet unchanged. A reader login over that path is first
tried from the teammate's device (step 6): the loopback test above went
through the existing `127.0.0.1` line, not the new ones. The policy template renders and parses with sample
logins; Tailscale has not checked it yet (step 3).
