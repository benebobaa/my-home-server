# cloudflared — the tunnel connector

The in-cluster end of Kubeletto's Cloudflare Tunnel
([ADR 0004](../../docs/decisions/0004-public-ingress-cloudflare-tunnel.md)).
The tunnel and its ingress rules are `network/cloudflare/tunnel.tf`; that stack
also runs `deploy.sh` inside VM 300 (guest agent, token on stdin).

| | |
| --- | --- |
| Tunnel | `kubeletto-home`, remote-managed (rules at Cloudflare, applied live) |
| Routes | `api.kubeletto.com`, `*.kubeletto.app` → `https://traefik.traefik.svc.cluster.local:443` (SNI = request host, certificate verified); anything else 404. Public only once the DNS record is a CNAME to the tunnel (cutover) |
| Pods | namespace `cloudflared` (PSA restricted), 2 replicas, **server node `k3s` only**: the token can serve every routed hostname, so it never sits on the worker with tenant code |
| Image | `cloudflare/cloudflared:2026.10.0`, pinned by digest, `--no-autoupdate` |
| Token | Secret `cloudflared/tunnel-token` (encrypted at rest by K3s); rotating it = replacing the tunnel in Tofu, the pods roll on the new hash |

```bash
ssh root@10.10.10.12 'qm guest exec 300 -- /usr/local/bin/k3s kubectl -n cloudflared get pods -o wide'
ssh root@10.10.10.12 'qm guest exec 300 -- /usr/local/bin/k3s kubectl -n cloudflared logs deploy/cloudflared --tail=20'
```

Destroying the tunnel: Cloudflare refuses while connectors are attached —
`kubectl -n cloudflared scale deploy/cloudflared --replicas=0` first.
