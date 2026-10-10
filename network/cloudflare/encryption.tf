# State + plan encryption (OpenTofu native, client-side AES-GCM). The state
# holds secrets in plaintext otherwise, and it only ever lived on the
# operator's laptop. Encrypted, it can be committed (history + off-machine
# copy) — see docs/runbooks/secrets.md.
#
# The passphrase is TF_VAR_state_passphrase in secrets.sops.env, so run tofu as:
#   sops exec-env secrets.sops.env 'tofu plan'
variable "state_passphrase" {
  description = "State encryption passphrase (from secrets.sops.env via sops exec-env)."
  type        = string
  sensitive   = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true # never write plaintext, even by mistake
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true # never write plaintext, even by mistake
    }
  }
}
