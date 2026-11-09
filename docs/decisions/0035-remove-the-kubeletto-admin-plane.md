# 0035 — The Kubeletto admin plane is removed

**Status:** accepted (2026-11-09). Supersedes [ADR 0026](0026-admin-plane-separate-from-the-customer-api.md) and [ADR 0027](0027-admin-plane-on-the-tailnet.md) in full.

## Context

ADR 0026 split Kubeletto's admin API into its own process and ADR 0027 put it on the operator's tailnet. It was built, deployed (pod `platform-admin`, an ephemeral tailnet node tagged `tag:admin`) and never put to work: one account was created and logged in once on 2026-10-28 to check it, and the audit log holds no admin action since. It still cost an extra image build, a tailnet auth key kept in SOPS, a tailnet policy tag and grant, and a second run mode of core.

## Decision

- **The admin plane is gone.** Kubeletto's repo removed the console (`apps/admin`), the `/v1/admin/*` API, `RUN_MODE=admin`, `ADMIN_API_ENABLED`, `bootstrap-admin` and the pod's manifests (Kubeletto D30). A tenant is suspended or restored with SQL, as the runbook already described.
- **Live objects deleted on 2026-11-09:** Deployment, NetworkPolicy, four ConfigMaps and the `platform-admin-tailscale` Secret in the `platform` namespace. The customer API was unaffected: it answers `/v1/admin/*` exactly as it answers any path that does not exist.
- **Here:** `services/kubeletto/admin-bootstrap.sh` and `tailnet-admin-key.sh` are removed, `pin.sh` pins core only, `PLATFORM_ADMIN_TS_AUTHKEY` is removed from `secrets.sops.env`, and `tag:admin` is removed from the tailnet policy template (owner, grant, tests).
- **The `admin_*` tables are dropped** (Kubeletto migration 106, applied 2026-11-09 after the core without the admin code was live): five tables and `feedback.reviewed_by` / `reviewed_at`. They held one account, one expired session and one audit row. The rows are in the PBS and pgBackRest backups; the migration's Down section recreates the empty structures.

## Consequences

- One image, one run-mode set (`api`, `worker`, `all`), no tailnet node for Kubeletto.
- The tailnet policy in the console still has `tag:admin` until the operator pastes the rendered template (`network/tailscale/README.md`). The auth key stays valid until the operator revokes it in the Tailscale console. Both are account-level steps.
- Feedback moderation went with the admin API. Feedback is still collected and nothing reads approved rows.
