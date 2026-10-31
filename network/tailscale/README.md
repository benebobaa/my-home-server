# tailscale — the tailnet policy

Who on the tailnet reaches what ([ADR 0029](../../docs/decisions/0029-teammates-read-only-on-the-tailnet.md)).
Until 2026-10-31 the tailnet ran Tailscale's default policy (everyone reaches
everything), which was fine while the operator was its only user.

| | |
| --- | --- |
| Policy | `policy.hujson`, with `${...}` where a login goes |
| Logins | `identities.sops.env` (the repo is public): `OPERATOR_LOGIN`, `LARASROUTER_READERS` as `handle=login,...` |
| Applied by | `./render-policy.sh \| pbcopy`, pasted in the admin console (Access controls → JSON editor). No API key: the console is the only writer |
| Guard | the `tests` block: the console refuses to save a policy that fails one. Every reader is tested against the management plane, the switch, the `ai` VM, `archive` and `tag:admin` |

What it grants:

| Who | Reaches |
| --- | --- |
| `group:operator` | everything (as before) |
| `autogroup:shared` (Irene, through the `archive` share) | the shared machine on 443 |
| `group:larasrouter-readers` | `10.10.20.21:5432` and `10.10.20.23:6381` only, through the admin gateways' routes; Postgres and Valkey then admit only their read-only logins ([services/postgres](../../services/postgres/README.md#read-only-access-for-a-person), [services/valkey](../../services/valkey/README.md#read-only-access-for-a-person)) |
| tagged nodes (`tag:admin`) | nothing; they are only reached |

## Changing it

1. Edit `policy.hujson` (or the logins: `sops network/tailscale/identities.sops.env`).
2. **From the home LAN** (not over Tailscale): in the admin console, copy the
   current policy somewhere safe first: it is the rollback.
3. `network/tailscale/render-policy.sh | pbcopy`, paste over the policy, save.
   If a test fails, the console says which and saves nothing.
4. Check from the Mac: the Proxmox UI and `ssh root@10.10.10.12` still work;
   for a reader change, the reader's own check (below).
5. Commit the template change.

## Adding a person who reads larasrouter's database

1. Add a handle (`reader2`, not a name) to `postgres_readers.larasrouter.people`
   in `postgres.tf` and to `valkey_readers.larasrouter` in `valkey.tf`, then
   `tofu apply` (targeted at `terraform_data.postgres_readers` and
   `terraform_data.valkey_instances` while the stack has unrelated drift).
2. `sops network/tailscale/identities.sops.env`: append `,reader2=<their Tailscale login>`
   to `LARASROUTER_READERS`, then render and paste (above).
3. Admin console → Users → Invite users, with that login. They install Tailscale
   and sign in; "Use Tailscale subnets" must be on (macOS and Windows: on by
   default; Linux: `tailscale up --accept-routes`). Leave key expiry on.
4. Give them `services/larasrouter/urls.sh reader larasrouter_reader2` and
   `urls.sh redis-reader larasrouter_reader2` over a private channel. From their
   machine: `SELECT` and a Valkey `SCAN` work, and the Proxmox UI
   (`https://10.10.10.12:8006`) times out.

Removing someone: take them out of `people`, `valkey_readers` and
`LARASROUTER_READERS`, apply and paste, remove the user in the admin console.
`readers.sh` turns their Postgres login off and ends their sessions;
`instances.sh` deletes their Valkey user, which closes its connections.

## Not carried over from the default policy

The default policy also had an `ssh` block (Tailscale SSH to one's own
devices) and a `nodeAttrs` entry allowing Funnel. Neither is used here: SSH is
OpenSSH with keys, `archive` uses `tailscale serve`, not Funnel. Add them
back if that changes.
