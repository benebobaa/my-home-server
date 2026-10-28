# 0026 — The admin API is a separate plane, on its own hostname

**Status:** accepted (2026-10-28). Supersedes the part of the Kubeletto migration that served `/v1/admin/*` from the customer API host (`docs/migration/README.md` in the Kubeletto repo, and its platform-core deployment). The admin session, TOTP and rate limits (Kubeletto `apps/core/internal/httpapi/admin_*.go`) stand.

## Context

The admin API (`/v1/admin/*`) ran inside the customer-facing core server, on `api.kubeletto.com`. A live check on 2026-10-28 returned 401 for an unauthenticated request from the internet. The only protection was the admin login, with TOTP and a generic rate limit. A bug or a stolen session on the customer host reaches the admin plane, and the admin surface shares every customer-side setting.

## Decision

- **The admin plane is a separate process:** the platform-core image in `RUN_MODE=admin`. It serves `/v1/admin/*` and the health probes, and nothing else. It starts no background workers and no internal listener. The route registration is shared with the customer server, so both expose the same admin routes.
- **Its own Kubernetes objects:** a `platform-admin` Deployment, Service and NetworkPolicy in the `platform` namespace. The NetworkPolicy allows ingress only from Traefik. The same secret, image and placement as core.
- **Its own hostname:** `admin-api.kubeletto.com`, routed by Traefik to `platform-admin`. The admin console calls this host.
- **Core stops serving the admin plane** once the admin host is live: `ADMIN_API_ENABLED=false` on the customer core. That flip is a separate, operator-approved step, so the admin tool is never down without a replacement.
- **Access in front of the admin host:** a Cloudflare Access policy that allows only the operator (ADR 0026 does not replace the admin login and TOTP; they still apply).

## Consequences

- The customer host stops serving admin routes. A future admin bug cannot be reached through the customer API.
- The admin plane has its own logs, rate limits and pods, and can later get its own database role. Today it uses the same role as core, which is the main gap left.
- A second pod runs on the server node (about 128 MB requested, 384 MB limit). VM 300 has about 1.9 GB available.
- The admin app's default API host changes to `admin-api.kubeletto.com`. Until the admin host is live, the admin app can't reach its API.
- The public DNS record for `admin-api` is gated behind `admin_api_public`, which defaults to false, so applying the stack cannot publish the admin login by accident. The Cloudflare token in the repo is invalid (401), and Access is not enabled on the account. Both are operator steps.

## Rollout

1. Operator: enable Cloudflare Access, and replace the invalid token (`network/cloudflare/secrets.sops.env`).
2. Set `admin_api_public = true` in the Cloudflare stack (`records.tf`, default false) and apply. Only after step 1 is in force: the record publishes the admin host.
3. Merge the Kubeletto `admin-service` branch into `home-migration`, push (the images workflow builds core), bump the core image pin, and apply the platform step. This starts the admin pod. Customer core keeps serving `/v1/admin` for now.
4. Verify the admin pod in the cluster: `/healthz` 200; `/v1/admin/stats` 401 with no session; `/v1/projects` 404.
5. Operator: deploy the admin app (its default host is now `admin-api.kubeletto.com`), log in through Access, and confirm the admin tool works.
6. Flip `ADMIN_API_ENABLED=false` on the customer core (`platform-core-patch.yaml`, explicit env, which overrides the secret) and apply. Verify `api.kubeletto.com/v1/admin/stats` returns 404.

## Verification

- Kubeletto repo, branch `admin-service` (`c73bb5a8`): `go build`, `go vet`, the new tests (admin-only route set, probes, the admin gate, the disabled flag, the monolith keeping its admin routes, the run-mode parse). The full core run has only the known payments failure. The admin app: typecheck and 157 tests pass. The home overlay renders.
- Cluster, 2026-10-28 (core image `c73bb5a8`, merged to `home-migration`): the `platform-admin` pod runs on the server node, `run_mode=admin`, `worker_enabled=false`, the schema guard passes at 102, and no worker starts. Through a port-forward: `/healthz` 200, `/readyz` 200, `/v1/admin/stats` 401 with no session, `/v1/projects` 404, `/v1/logs` 404. The customer core is still up.
- Not yet: the admin host through Cloudflare (gated by `admin_api_public`, operator's Access step first), the admin app deploy, and the flip of `ADMIN_API_ENABLED` on the customer core.

## Follow-ups

- A least-privilege database role for the admin plane (read and admin writes only, no worker tables).
- Access policy as code, once the Cloudflare token has the Access permission.
- Tailnet-only access, if the operator wants zero public surface. This changes only the ingress for `admin-api`.
- Defence in depth: the admin plane checks Cloudflare Access's `Cf-Access-Jwt-Assertion` header, so a request that bypasses Access is refused by the app too. This is the review's suggestion, and it is worth doing before the host is published.
