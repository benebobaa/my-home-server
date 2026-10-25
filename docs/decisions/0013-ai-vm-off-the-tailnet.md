# 0013 — The `ai` VM stays off the tailnet and out of the log store

**Status:** accepted (2026-10-13). Supersedes the access line of
[ADR 0012](0012-pve1-on-demand-ai-workstation.md) ("over Tailscale running
in the VM") and its `logs: true`.

## Context

ADR 0012 put the AI workstation VM `ai` on the LAB VLAN because it runs
untrusted code: pip packages, model-hub downloads, GitHub repositories. The
first build then gave it two paths out of that VLAN, which the automatic
security review of the commit flagged:

- **Tailscale in the VM.** The tailnet runs the default allow-all policy,
  and the admin gateways advertise `10.10.10.0/24` (MGMT: the Proxmox
  nodes). The VM's user has passwordless sudo, so any code that gets root
  could run `tailscale set --accept-routes` and reach MGMT through the
  gateways, around the hEX's inter-VLAN deny.
- **Journal shipping** to VictoriaLogs (`logs`, `10.10.10.18:9428`). The
  same port serves queries, so the VM could read the whole lab's logs. The
  DMZ is refused `logs: true` for this reason (ADR 0008).

The VM's Tailscale login was cancelled before anyone completed it.

## Decision

- **`ai` is never on the tailnet.** The operator reaches it through the
  admin gateways like any lab host: both advertise `10.10.30.10/32`
  (`services/admin-gw/provision.sh`), and the hEX already lets them reach
  every lab VLAN. Traffic arrives SNATed from a gateway; the VM can answer
  but cannot open anything towards MGMT (inter-VLAN default deny).
- **`ai` ships no logs** (`logs: false`), so the hEX has no LAB → `logs`
  pinhole for it. `provision.sh` purges Tailscale and the journal uploader
  if a host still has them.
- Treat the LAB VLAN like the DMZ for anything running untrusted code: no
  push into MGMT, no tailnet membership.

## Consequences

- Access needs the new route approved once in the Tailscale admin console
  (both gateways), then `ssh bene@10.10.30.10` from the Mac, at home or
  away. Ports (Jupyter, vLLM) go through SSH forwarding (`ssh -L`).
- `ai`'s logs stay in its own journal; it is watched by ping and the PVE
  API only.
- A restrictive tailnet policy (policy as code) remains open; until then
  nothing that runs untrusted code joins the tailnet.
