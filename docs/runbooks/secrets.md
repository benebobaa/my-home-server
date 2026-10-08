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
| `proxmox/opentofu/secrets.sops.env` | `PROXMOX_VE_API_TOKEN`, `TF_VAR_state_passphrase` |
| `network/routeros/secrets.sops.env` | `ROS_USERNAME`, `ROS_PASSWORD`, `TF_VAR_state_passphrase` |
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

## Adding a machine or CI later

Generate an age key there, append its public key to `.sops.yaml`
(`age: >- key1,key2`), run `sops updatekeys -y` on each secrets file.

## Concurrency note

State in git suits a single operator. If a second operator or CI ever
applies, move state to a locking backend (e.g. S3-compatible on the future
PBS/MinIO) — the encryption config stays the same.
