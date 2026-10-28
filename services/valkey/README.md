# valkey — the lab's shared Valkey (cache)

One container, one Valkey **process per app**: its own TLS port, password,
`maxmemory` and exporter. No persistence: a cache by definition. Why one
process per app and not one shared keyspace: [ADR 0016](../../docs/decisions/0016-shared-nats-and-valkey.md).

| | |
| --- | --- |
| Guest | CT 132 `valkey`, pve3 (nothing to keep, off pve2's CPU), VLAN 20, `10.10.20.23`, `valkey.home.arpa` |
| Built by | `proxmox/opentofu/valkey.tf` → `setup.sh` (Debian's `valkey-server` 8.1 and `prometheus-redis-exporter`), `instances.sh` (one instance per entry of `local.valkey_instances`) |
| Instances | `valkey-server@<app>` (Debian's template unit), config `/etc/valkey/valkey-<app>.conf`; `redis-exporter@<app>` reads it over its unix socket |
| Ports | per app from 6380 (TLS only, no plaintext port); exporters from 9121 |
| State | none (no RDB, no AOF). A restart empties the instance |
| TLS | self-signed, from OpenTofu (`tls_self_signed_cert.valkey`: `valkey.home.arpa` + the IP), installed by `tls.sh`; output `valkey_tls_cert` to pin (ADR 0017) |
| Watched | `redis_up` and memory per exporter (`app-valkey.yml`), journal to `logs` |
| Firewall | nftables in the CT: exporters (9121-9199) only from the monitoring host (`/scrape?target=` would hand an instance's password to any target); instances open to VLAN 20 and the pinholes, password required |
| Boot | instances bind the CT's address before it exists (`net.ipv4.ip_nonlocal_bind`, this CT only) and restart every 2 s: the first boot lost the bind race |

| App | Port | Exporter | maxmemory | Policy |
| --- | --- | --- | --- | --- |
| kubeletto | 6380 | 9121 | 96 MB | volatile-lru (its locks and rate limits carry TTLs) |
| larasrouter | 6381 | 9122 | 64 MB | volatile-lru (session cache, cooldowns and the sweeper lock carry TTLs); a tenant app in the DMZ, reached from the K3s worker through its own pinhole (ADR 0022) |

## Giving an app an instance

1. Add it to `local.valkey_instances` in `proxmox/opentofu/valkey.tf` (next
   port, next exporter port, `maxmemory`, policy) and its exporter port to
   `valkey.monitoring.metrics` in `inventory/lab.yaml` (a precondition fails
   the apply otherwise; lab.yaml also opens the hEX for the scrape). The CT
   has 256 MB: the sum of `maxmemory` stays well under it.
2. **The second app needs one monitoring change first:** targets label every
   port of a host `instance="valkey"`, so two exporters would produce the
   same series. Give `service` targets a `port` label per metrics port in
   `proxmox/opentofu/monitoring.tf` (or split the instance label) before
   adding a second exporter port.
3. `tofu apply` (both stacks: routeros for the new scrape port). Deliver the
   password (`random_password.valkey["<app>"]`) to the app.

Connect: `rediss://:<password>@valkey.home.arpa:<port>/0`, verifying against
the certificate OpenTofu generated (`tofu output -raw valkey_tls_cert` in
`proxmox/opentofu`; ADR 0017). Kubeletto's core: `REDIS_TLS_CA` with that PEM.
Proven 2026-10-15 from VLAN 20 with go-redis (Kubeletto's client): pinned
SET/GET/SETNX over TLS, unpinned refused.

Kubeletto uses its instance only after its switch (`services/nats/README.md`,
"Kubeletto's switch"); until then its core uses the in-cluster Valkey.

## Operations

- **Check an instance:** in the CT, `REDISCLI_AUTH=<pw> valkey-cli --tls --insecure -h 10.10.20.23 -p <port> info`
  (Debian's valkey-cli 8.1 reads `REDISCLI_AUTH`, not `VALKEYCLI_AUTH`; the
  password is in the instance's config, root/valkey only).
- **Rotate a password:** `tofu apply -replace='random_password.valkey["<app>"]'`
  (the instance restarts, its cache empties), then the app.
- **Remove an app:** delete its entry; `instances.sh` stops it and removes its
  config (nothing to keep).
- **Rebuild:** always safe, nothing is stored: `tofu apply -replace=module.valkey.proxmox_virtual_environment_container.this`.
