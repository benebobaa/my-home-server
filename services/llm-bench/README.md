# llm-bench — the LLM serving bench client (temporary)

CT 201 on **pve2**, `10.10.20.40` (`llm-bench.home.arpa`), VLAN 20. The load
generator for benchmarking Ollama, vLLM and SGLang on the `ai` VM's RTX 3060.
**Temporary:** it and everything below goes once the article is published
([ADR 0019](../../docs/decisions/0019-temporary-llm-serving-bench-lab.md)).

| | |
| --- | --- |
| Guest | Debian 13, unprivileged, 4 cores, 2 GB, 32 GB, PBS nightly |
| Tools | venv `/opt/bench/venv` (active at login): GuideLLM 0.8.1, lm-eval 0.4.13 (`[api]`), pandas, matplotlib, torch 2.14.1 CPU |
| Results | `/opt/bench/results` (backed up; `ai` is not) |
| Reaches | `ai:8000` only (hEX rule `bench lab: llm-bench to ai engine API`), plus the internet |
| Monitoring | ping; best-effort. No log shipping (runs PyPI / model-hub code; ADR 0019): `journalctl` in the CT |

## How it fits

```
llm-bench (VLAN 20) ──tcp/8000──▶ ai (LAB, pve1): engine on :8000
monitoring (VLAN 10) ──9100, 9835, 8000/metrics──▶ ai
ai ──✕──▶ any lab VLAN (default deny)    ai ──▶ internet (kill switch below)
```

In `ai` (`services/ai/provision.sh`): chrony, node_exporter `:9100`, the GPU
exporter `:9835`, `/data/models` and `/data/results` on the root disk, and
the disk snapshot `bench-baseline` (driver, CUDA, Docker GPU runtime,
exporters; no engines, no models).

## Use

```bash
ssh -J root@10.10.10.17 root@10.10.20.40 # jump via admin-gw2 (or .15): the gateways route MGMT + ai, not VLAN 20
curl -s http://10.10.30.10:8000/v1/models
guidellm benchmark --target http://10.10.30.10:8000 ... --output-path /opt/bench/results/<run>.json
lm_eval --model local-completions --model_args base_url=http://10.10.30.10:8000/v1/completions,model=<id> ...
```

Engines on `ai` must listen on `0.0.0.0:8000` (Docker: `-p 8000:8000`), and
vLLM/SGLang serve `/metrics` there (SGLang: `--enable-metrics`). Models go in
`/data/models` (e.g. `-v /data/models:/root/.cache/huggingface`).
Grafana: **Nvidia GPU Metrics** for the card; Explore on `{instance="ai"}`
for node_exporter and the engine's own series (`vllm:*`, `sglang:*`).

## Cut `ai`'s internet during a run

The hEX rule `block ai internet during runs` is disabled by default; flip it
by hand (OpenTofu ignores this attribute, so it is not drift). From WinBox /
SSH on the hEX (`10.10.10.1`):

```
/ip firewall filter enable [find comment="block ai internet during runs"]
/ip firewall connection remove [find src-address~"^10.10.30.10:"]   # cut running downloads too (fasttracked otherwise)
/ip firewall filter disable [find comment="block ai internet during runs"]
```

DNS still answers (it is the hEX itself) and chrony keeps the time it has.

## Return `ai` to the baseline

On pve1: `qm rollback 140 bench-baseline && qm start 140`. It stops the VM and
wipes everything since the snapshot, `/data` included: copy results to
`llm-bench` first.

## Teardown (after the article)

One commit, then converge (`tofu apply` in both stacks, pve1 up for the
`ai` part):

1. `inventory/lab.yaml`: delete the `llm-bench` host; `ai` metrics back to `[9835]`.
2. Delete `proxmox/opentofu/llm-bench.tf` and `services/llm-bench/`.
3. `network/routeros/firewall.tf`: delete `forward_bench_ai` and
   `forward_ai_no_internet`.
4. `services/ai/provision.sh`: delete the bench block; in its place, once,
   `apt purge prometheus-node-exporter` (keep chrony if you like it) and
   `rm -rf /data` if nothing is left there. `services/ai/converge.sh`: delete
   the snapshot block.
5. On pve1: `qm delsnapshot 140 bench-baseline`.
6. Docs: a short ADR superseding 0019; remove the bench lines from
   `services/ai/README.md`, `docs/standards/observability.md`,
   `docs/design/network-design.md` and README → Status.
7. Verify: both plans `No changes`; `curl` from VLAN 20 to `ai:8000` times
   out; Prometheus has no `ai:9100`/`ai:8000` targets. The PBS backups of
   CT 201 age out with the prune policy (or delete them in the PBS UI).
