# Runbook: secrets (SOPS + age) and encrypted IaC state

**Since 2026-10-08.** Secrets live in git, encrypted. OpenTofu state is
encrypted too and committed. **One age key** on the operator's Mac decrypts
everything:

```text
age key (~/Library/Application Support/sops/age/keys.txt)
  └─ decrypts  *.sops.env  (API token, router creds, state passphrases)
       └─ TF_VAR_state_passphrase decrypts  terraform.tfstate  (per stack)
```

## ⚠️ Back up the age key — first thing

If the key is lost, the repo's secrets and the encrypted state cannot be
read by anyone. Copy the **whole file** into your password manager now:

```bash
cat ~/Library/Application\ Support/sops/age/keys.txt   # 3 lines: comment, public key, AGE-SECRET-KEY-…
```

Public key (safe to share, also in `.sops.yaml`):
`age17l5vheelwnd23jqy4754ythtwcamq8u79pfu5dmcdka36nth59aq0hlypw`

Restore on a new machine: put the file back at that path (macOS) or at
`~/.config/sops/age/keys.txt` (Linux), mode `600`.

## Daily use

| Task | Command |
| --- | --- |
| Run OpenTofu | `sops exec-env secrets.sops.env 'tofu plan'` (in the stack dir) |
| Edit a secret | `sops edit proxmox/opentofu/secrets.sops.env` |
| Read one value | `sops decrypt --extract '["ROS_USERNAME"]' network/routeros/secrets.sops.env` |
| New secrets file | create it as `<name>.sops.env` / `.sops.yaml` → `sops edit <file>` (`.sops.yaml` picks the key) |
| Router snapshot | `./scripts/hex-snapshot.sh` (decrypts in memory) |

`sops exec-env` puts the values into the command's environment only —
nothing is written to disk, and values with special characters (the
Proxmox token has a `!`) need no shell quoting.

## What is where

| File | Holds |
| --- | --- |
| `proxmox/opentofu/secrets.sops.env` | `PROXMOX_VE_API_TOKEN`, `TF_VAR_state_passphrase`, archive passwords, `TF_VAR_monitoring_*` (Grafana admin, SNMPv3 auth/priv, Telegram bot token + chat id, healthchecks.io ping URL), the Postgres off-site backup: `TF_VAR_postgres_b2_*`, `TF_VAR_postgres_offsite_cipher_pass` and the restore-only `POSTGRES_B2_RESTORE_*` (below) |
| `network/routeros/secrets.sops.env` | `ROS_USERNAME`, `ROS_PASSWORD`, `TF_VAR_state_passphrase`, `TF_VAR_snmp_auth_password`, `TF_VAR_snmp_priv_password` |

The SNMPv3 pair is deliberately in **both** files: the router stack sets it,
the monitoring CT uses it. Rotate together: `sops edit` both files with the
same new values, then `tofu apply` in `network/routeros` and then in
`proxmox/opentofu`. Compare them without printing:
`[ "$(sops decrypt --extract '["TF_VAR_snmp_auth_password"]' network/routeros/secrets.sops.env)" = "$(sops decrypt --extract '["TF_VAR_monitoring_snmp_auth_password"]' proxmox/opentofu/secrets.sops.env)" ] && echo match`.

Not in any file: the PVE API token of `prometheus@pve` (monitoring). It is
created on pve2 and written straight into CT 120. To rotate it, run
`pveum user token remove prometheus@pve monitoring` and then `tofu apply -replace=terraform_data.monitoring_pve_token`.
| `*/terraform.tfstate` | encrypted state (AES-GCM, PBKDF2 key) — `encryption.tf`, `enforced = true` |

The old plaintext `.env` files are no longer used by anything in the repo.
They stay git-ignored on the operator's Mac only as a fallback — **delete them
once the age key is backed up** (`rm proxmox/opentofu/.env network/routeros/.env`).

## Guard rails

- `encryption.tf` sets `enforced = true`: OpenTofu refuses to write plaintext
  state, and fails without the passphrase.
- Pre-commit hook `.githooks/pre-commit` blocks plaintext `*.tfstate`,
  non-encrypted `*.sops.*`, and any `.env` / `*.local.rsc`. Enable it once per
  clone: `git config core.hooksPath .githooks`.
- `*.tfstate.backup` stays git-ignored (only the live state is committed).

## Rotation

- **A credential** (token, router password): change it at the source, then
  `sops edit` the file. Commit.
- **The age key** (suspected leak): `age-keygen -o new.txt`, put the new public
  key in `.sops.yaml`, run `sops updatekeys -y <file>` for every `*.sops.*`
  file, then rotate every secret inside them (the old key could read them).
- **A state passphrase**: add the new one as a second `key_provider` +
  `fallback` in `encryption.tf`, `tofu apply -refresh-only`, then remove the
  old one. (The same pattern used for the plaintext → encrypted migration.)

## The off-site backup: B2 keys and the cipher passphrase

The shared Postgres archives to a Backblaze B2 bucket with pgBackRest
([ADR 0034](../decisions/0034-postgres-off-site-on-b2-with-pgbackrest.md),
[backup-restore.md](backup-restore.md#postgres-off-site-pgbackrest-in-b2)).
All of it in `proxmox/opentofu/secrets.sops.env`:

| Key | What | Where it goes |
| --- | --- | --- |
| `TF_VAR_postgres_b2_key_id` | B2 application key ID, **read and write, this bucket only** | CT 130 `/etc/pgbackrest/pgbackrest.conf` (root:postgres 0640), via `terraform_data.postgres_offsite` on stdin |
| `TF_VAR_postgres_b2_app_key` | that key's secret | same |
| `TF_VAR_postgres_b2_bucket` | the bucket's name (private) | same |
| `TF_VAR_postgres_b2_endpoint` | `s3.<region>.backblazeb2.com`, no `https://` | same |
| `TF_VAR_postgres_b2_region` | `<region>` from the endpoint | same |
| `TF_VAR_postgres_offsite_cipher_pass` | pgBackRest's `repo1-cipher-pass` (aes-256-cbc), 32+ characters | same. **Also in the password manager**: without it every off-site backup is unreadable |
| `POSTGRES_B2_RESTORE_KEY_ID` | a second B2 key, **read only, this bucket only** | nowhere in the lab: restores and drills only (no `TF_VAR_` prefix, Tofu ignores it) |
| `POSTGRES_B2_RESTORE_APP_KEY` | its secret | same |

Adding them the first time (the file exists; `sops edit` opens it decrypted
in `$EDITOR` and re-encrypts on save):

```bash
openssl rand -base64 48 | tr -d '\n'; echo     # the cipher passphrase: paste it into the file AND the password manager
sops edit proxmox/opentofu/secrets.sops.env
#   TF_VAR_postgres_b2_key_id=...
#   TF_VAR_postgres_b2_app_key=...
#   TF_VAR_postgres_b2_bucket=...
#   TF_VAR_postgres_b2_endpoint=s3.<region>.backblazeb2.com
#   TF_VAR_postgres_b2_region=<region>
#   TF_VAR_postgres_offsite_cipher_pass=...
#   POSTGRES_B2_RESTORE_KEY_ID=...
#   POSTGRES_B2_RESTORE_APP_KEY=...
```

Until `TF_VAR_postgres_b2_key_id` is set, `terraform_data.postgres_offsite`
has `count = 0` and the plan does not change.

**Rotate the B2 key** (CT 130's, read and write; e.g. once a year or if CT
130 or the file may have leaked): B2 → *Application Keys* → add a new key
with the same settings → `sops edit` the two `TF_VAR_postgres_b2_key*` values
→ `tofu apply` in `proxmox/opentofu` (`offsite.sh` rewrites the config and
runs `stanza-create`, a no-op on the existing stanza; no restart) →
`pct exec 130 -- runuser -u postgres -- pgbackrest --stanza=main check` →
delete the old key in B2. Archiving stalls only between deleting the old key
and the apply, so delete it last. The read-only key: the same in B2 and
`sops edit`, nothing in the lab to apply.

**Rotate the cipher passphrase:** pgBackRest cannot re-encrypt a repo, and
every file in it was encrypted with the old one. So rotation is a new repo:

1. Generate a new passphrase (above); keep the old one in the password
   manager until step 4.
2. `sops edit`: the new `TF_VAR_postgres_offsite_cipher_pass`.
3. In CT 130 as `postgres`: `pgbackrest --stanza=main stop`, then
   `pgbackrest --stanza=main stanza-delete --force` (the bucket's history is
   gone from here on; PBS keeps the home history), `pgbackrest --stanza=main start`.
   Then `tofu apply` in `proxmox/opentofu`: `offsite.sh` writes the new
   passphrase, creates the stanza afresh, runs `check` and starts a full.
   WAL written during these minutes waits in `pg_wal` and is pushed after.
4. Once `pgbackrest info` shows the new full: drop the old passphrase.

Rotate it only if it may have leaked: the new repo starts with no restore
window until its first full is done.

## Adding a machine or CI later

Generate an age key there, append its public key to `.sops.yaml`
(`age: >- key1,key2`), run `sops updatekeys -y` on each secrets file.

## Concurrency note

State in git suits a single operator. If a second operator or CI ever
applies, move state to a locking backend (e.g. S3-compatible on the future
PBS/MinIO) — the encryption config stays the same.
