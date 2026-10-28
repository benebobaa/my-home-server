# 0027 — The admin plane is on the operator's tailnet, not the public internet

**Status:** accepted (2026-10-28). Supersedes [ADR 0026](0026-admin-plane-separate-from-the-customer-api.md)'s public hostname (`admin-api.kubeletto.com`) and its Cloudflare Access step. ADR 0026's separate admin process stands.

## Context

ADR 0026 split the admin API into its own process, but kept it on a public hostname behind Cloudflare Access. Access needs a Zero Trust setup and a Cloudflare token with Access permission. At the time of writing, the token is invalid (401) and Access is not enabled on the account. The public hostname also exposed the admin login to the internet. Gating it with a flag was a stop-gap, not a fix.

The operator already reaches everything over Tailscale: the Mac, and the `admin-gw` subnet routers on the same tailnet. Tenant pods are denied the tailnet's 100.64.0.0/10 range (`TENANT_EGRESS_DENY_CIDRS`), and the cluster reaches Tailscale's control plane on 443 (checked 2026-10-28).

## Decision

- **The admin console and its API are reachable only on the operator's tailnet**, at `https://kubeletto-admin.<tailnet>.ts.net`. There is no public DNS record and no Traefik route for them.
- **One pod, three containers, sharing localhost** (`infra/k8s/home/platform-admin.yaml`, Kubeletto repo):
  - `tailscale` (pinned `v1.104.2`) joins the tailnet as an ephemeral node with tag `tag:admin`, and runs `tailscale serve` to publish the UI. It uses the CLI, not `TS_SERVE_CONFIG`, which has open issues where JSON-defined services are not advertised.
  - `admin-ui` (nginx, unprivileged) serves the admin console and proxies `/v1/` to the API on the same origin. So the console needs no CORS.
  - `platform-admin` is the platform-core image in `RUN_MODE=admin` (ADR 0026): `/v1/admin/*` and the probes only.
- **No ingress into the pod.** The NetworkPolicy allows no ingress, so nothing in the cluster, the tenant zone or Traefik can call the admin plane.
- **Access control is Tailscale's:** only the operator's devices may reach `tag:admin` (an ACL grant, operator step). The admin login, TOTP and session checks still apply inside.
- **The auth key** is a reusable, ephemeral, pre-authorized key for `tag:admin`, kept in `services/kubeletto/secrets.sops.env` as `PLATFORM_ADMIN_TS_AUTHKEY`. `services/kubeletto/tailnet-admin-key.sh` creates the `platform-admin-tailscale` Secret from it, through the guest agent, without writing it to disk or argv.
- **The admin app's default API base is the same origin** (empty string), so it works wherever the pod serves it.

## Consequences

- **No edge login and no Cloudflare dependency for the admin plane.** The Cloudflare token and Access are no longer needed for it.
- **Access requires Tailscale.** A device without Tailscale can't reach the admin plane. Break-glass stays as it was: root SSH to pve2 and `qm guest exec`.
- **The customer API host still serves `/v1/admin`** until the customer core's `ADMIN_API_ENABLED` is set to false. That flip is the last step below.
- **Tailnet state is in memory**, so each pod start is a new ephemeral node named `kubeletto-admin`. The `Recreate` strategy keeps one node at a time.
- **The public Pages admin project becomes unused** once the tailnet console works. Retire it then.
- **Tailnet trust.** The default ACL allows every device to reach everything. Restricting `tag:admin` to the operator is required before the key is used (see steps).

## Rollout

Operator steps (Tailscale admin console):
1. **DNS:** enable MagicDNS and HTTPS certificates for the tailnet. `tailscale serve` needs both.
2. **ACL:** add `tag:admin` with `tagOwners` for the operator's user, and a grant allowing only the operator's user to reach `tag:admin` on 443. Tighten the default allow-all for this tag.
3. **Auth key:** generate a key that is reusable, ephemeral, pre-authorized and tagged `tag:admin`. Put it in `services/kubeletto/secrets.sops.env` as `PLATFORM_ADMIN_TS_AUTHKEY` (`sops services/kubeletto/secrets.sops.env`).

Then, in the homeserver repo:
4. `services/kubeletto/tailnet-admin-key.sh`, to create the Secret.
5. Kubeletto repo: merge `admin-tailnet` into `home-migration`, push (the images workflow builds `kubeletto-admin-ui`), bump the `kubeletto/admin-ui` image pin in `infra/k8s/home/kustomization.yaml`, and run `./apply.sh platform`.
6. Delete the objects ADR 0026 left in the cluster, which `apply` does not prune: the `admin-api` IngressRoute in `traefik`, and the `platform-admin` Service in `platform`.
7. Verify from a tailnet device: the console loads, `/v1/admin/stats` returns 401 with no session, and `https://kubeletto-admin.<tailnet>.ts.net` is unreachable from a device not on the tailnet.
8. Set `ADMIN_API_ENABLED=false` on the customer core (explicit env in `platform-core-patch.yaml`) and apply. Verify `api.kubeletto.com/v1/admin/stats` returns 404.
9. Retire the Pages admin project.

## Verification

- Kubeletto repo, `admin-tailnet` (`b792dd8e`): the overlay renders. The admin app typechecks and passes its 157 tests. The admin UI image builds from the committed tree. Run locally, it serves the console (200), falls back to the app for unknown paths, proxies `/v1/` (502 with no API present, as expected), sets the security headers, and runs as uid 101.
- Not yet: the tailnet join, the `tailscale serve` publish, the ACL and the HTTPS certificate (operator steps 1–3), and the flip on the customer core.
