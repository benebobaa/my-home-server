# Runbook: Secure Boot + DKMS module signing (MOK) on PVE nodes

**When:** a node has **Secure Boot enabled** and you need to load an unsigned/3rd-party
kernel module (e.g. the NVIDIA driver installed via `.run`, any DKMS module).
Symptom: `insmod`/`modprobe` fails with *"Key was rejected by service"*, and
`dmesg` shows *"Loading of unsigned module is rejected"*.

Two options — pick per node:

- **Option A (keep Secure Boot):** enroll a Machine Owner Key (MOK); sign the modules.
  One-time physical step, then DKMS signs future rebuilds automatically.
- **Option B (simpler, lower security):** disable Secure Boot in the BIOS.
  Unsigned modules load immediately. (**pve2 and pve3 both use this** — pve2 switched
  from A to B on 2026-10-08; the queued MOK was never enrolled.)

---

## Option A — MOK enrollment (keeps Secure Boot ON)

Was prepared on **pve2** but not used (pve2 went with Option B). Kept as the recipe
if a node ever needs Secure Boot ON.

1. **Key** (generated during the 2026-10-08 MX130 experiment, per node):
   ```bash
   mkdir -p /var/lib/shim-signed/mok
   openssl req -new -x509 -newkey rsa:2048 \
     -keyout /var/lib/shim-signed/mok/MOK.priv \
     -outform DER -out /var/lib/shim-signed/mok/MOK.der \
     -nodes -days 36500 -subj "/CN=homelab Secure Boot MOK/"
   chmod 600 /var/lib/shim-signed/mok/MOK.priv
   ```
2. **Queue it** (choose a one-time password; it is not stored in this repo):
   ```bash
   mokutil --import /var/lib/shim-signed/mok/MOK.der
   mokutil --list-new          # confirm it is pending
   ```
3. **Physical step at the machine** (one time):
   - Reboot with the lid open.
   - On the blue **MOK management** screen: press any key.
   - `Enroll MOK` → `Continue` → `Yes` → enter the **one-time password** → `Reboot`.
4. **Verify:** `mokutil --list-enrolled` shows the key. Modules signed with `MOK.priv`
   now load (`modinfo <module> | grep signer`).
5. **Future builds sign themselves** — dkms is configured:
   `/etc/dkms/framework.conf` contains
   ```ini
   mok_signing_key="/var/lib/shim-signed/mok/MOK.priv"
   mok_certificate="/var/lib/shim-signed/mok/MOK.der"
   ```

**Sign an already-built module manually:**
```bash
/usr/src/linux-headers-$(uname -r)/scripts/sign-file sha512 \
  /var/lib/shim-signed/mok/MOK.priv /var/lib/shim-signed/mok/MOK.der <module.ko>
```

**NVIDIA .run specifics (used for 580.178.04):**
```bash
sh NVIDIA-Linux-x86_64-580.178.04.run -s -z -j 4 --dkms \
  --module-signing-secret-key=/var/lib/shim-signed/mok/MOK.priv \
  --module-signing-public-key=/var/lib/shim-signed/mok/MOK.der \
  --skip-module-load        # install completes BEFORE enrollment; loads after reboot
```

## Option B — disable Secure Boot

ASUS laptops (pve2/pve3): reboot, tap **F2** at the logo → **F7** (Advanced Mode) →
**Security** → **Secure Boot** → *Secure Boot Control* = **Disabled** (if greyed out, set a
temporary Administrator Password first) → **F10** Save & Exit.
Verify: `mokutil --sb-state` → `SecureBoot disabled`.
(Everything else identical; no signing needed. This is what pve2 and pve3 run.)

## Gotchas

- Kernel **lockdown** (implied by Secure Boot) cannot be relaxed from the OS:
  `lockdown=none` and `module.sig_enforce=0` are ignored while Secure Boot is on.
- MOK enrollment is **pre-OS** (shim) — it cannot be done over SSH; it needs
  keyboard + screen on the machine. It does not block boot if skipped (times out).
- Debian 13's apt verifier (`sqv`) rejects repos whose signing keys carry SHA-1
  self-signatures (since 2026-02) — e.g. the legacy NVIDIA CUDA repos.
  Prefer runfile installers for such artifacts.
