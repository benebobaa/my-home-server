# 2026-10-11: K3s server refused to start ("passwd newer than datastore")

| | |
| --- | --- |
| **Status** | Resolved 2026-10-11 12:37 WIB |
| **Impact** | The home K3s control plane (`k3s`, VM 300) was down twice. The cluster was still empty (only the K3s system pods; Kubeletto still runs on the rented server), so nothing user-facing was affected. The worker kept running. |
| **Duration** | 12:29–12:31 and 12:32–12:37 WIB (about 7 min in total) |
| **Trigger** | A server config change (the control-plane taint, after a security review) restarted K3s |
| **Root cause** | The agent token had been introduced through config on a live cluster (commit 6e2bf8d, 2026-10-11 02:18). K3s rewrites `server/cred/passwd` on disk at every start to include the agent token, but never re-saves its datastore copy of the bootstrap files. From the second restart on, the disk file is newer than the datastore and K3s stops itself. |
| **Fix** | `k3s token rotate` to the **same** server token, which re-saves the bootstrap files into the datastore. No token changed anywhere. |

## Timeline (WIB)

| Time | Event |
| --- | --- |
| 02:18 | Commit 6e2bf8d: `install.sh` gives the worker its own agent token (`agent-token-file` on the server). K3s restarts, adds the token to `passwd` on disk, comes up fine. This masked the fault. |
| 12:28 | The push security review flags that tenant pods could schedule on the server node (cluster-admin token, the only address through the Postgres pinhole). The fix: a `NoSchedule` taint on `k3s` in `install.sh`. |
| 12:29 | Apply → `install.sh` rewrites the config → `systemctl restart k3s` → `level=fatal msg="/var/lib/rancher/k3s/server/cred/passwd newer than datastore and could cause a cluster outage"`, in a restart loop. The provisioner fails. |
| 12:31 | K3s's own remedy, run by the operator (the agent's remote write was blocked by the auto-mode classifier): back up and remove `passwd`, restart. Both nodes Ready; the rebuilt `passwd` has the same content as before (K3s re-added the agent token on start). |
| 12:32 | Test restart by the agent: the same fatal error. Proof that removal only fixes one boot, because the datastore copy was still the old one. |
| 12:37 | The operator runs the permanent fix: recover again, `k3s token rotate --new-token <the same token>`, then a test restart: `active`, 0 "newer than datastore" lines, both nodes Ready. |
| 12:40 | The taint apply completes without restarting K3s (config already on disk). A probe pod without a toleration schedules on `k3s-worker`. `proxmox/opentofu`: No changes. |

## Analysis

K3s keeps the server's bootstrap files (CA material, `passwd`, encryption
config) both on disk and, encrypted with the server token, in the datastore.
On start it reconciles the two. If they differ and the disk copy is newer, it
refuses to start rather than guess, because in an HA cluster a stale server
overwriting the datastore could break every other server.

Setting `agent-token-file` on an existing server changes `passwd` on disk at
the next start (the agent token is added as the `node` user), but the
datastore copy is only re-saved on bootstrap or token rotation. So the first
restart after the change succeeds and writes the newer file, and every
restart after that fails. The fault sat latent for ten hours because nothing
restarted K3s in between.

Removing the file (K3s's message suggests it) recreates it from the datastore,
and K3s then re-adds the agent token on the same start. That makes the disk
newer again, so it only buys one boot. `k3s token rotate` is the supported
online operation that saves the current bootstrap files back to the
datastore. Rotating to the same value changes nothing else: no token file,
no Tofu state, no worker rejoin.

## Action items

- [x] Rule in `services/k3s/install.sh` and `services/k3s/README.md`: never
      add or change the agent token on a running cluster through config
      alone. Rotate (`k3s token rotate`) or re-bootstrap.
- [x] Tenant pods cannot schedule on the server node (the original finding):
      `node-taint` in the server config, plus an idempotent `kubectl taint`.
- [ ] A test restart after any change to K3s's server config or tokens
      before calling it done. A single restart masked this fault for ten hours.
