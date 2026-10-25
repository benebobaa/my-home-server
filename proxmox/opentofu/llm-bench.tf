# llm-bench — TEMPORARY load-generator client for the LLM serving bench lab
# (ADR 0019): GuideLLM and lm-eval against the engine under test on `ai`
# (:8000, through one exact hEX pinhole). Service notes and the teardown
# list: services/llm-bench/README.md
#
# VLAN 20 with the other service containers; on pve2 (pve3 gets nothing
# new) with normal PBS backups, which keep the results. 2 GB, not 4: pve2
# has ~3 GB free and the model runs on `ai`, so the client stays light.

locals {
  llm_bench_dir = "${path.module}/../../services/llm-bench"
  llm_bench_ssh = local.node_ssh[local.host["llm-bench"].node]
  llm_bench_files_sha = sha256(join("", [
    for f in sort(fileset(local.llm_bench_dir, "**")) :
    filesha256("${local.llm_bench_dir}/${f}") if f != "README.md"
  ]))
}

module "llm_bench" {
  source = "./modules/lxc-guest"

  host             = local.host["llm-bench"]
  description      = "llm-bench — temporary LLM serving bench client (GuideLLM, lm-eval) → ai:8000 (ADR 0019). Managed by OpenTofu: proxmox/opentofu."
  tags             = ["llm-bench", "tofu"]
  template_file_id = proxmox_download_file.debian_13_template_pve2.id
  ssh_public_key   = local.admin_ssh_public_key

  cores     = 4
  memory_mb = 2048
  # venv (~1.5 GB, CPU torch), Hugging Face datasets/tokenizers, results.
  disk_gb = 32
}

resource "terraform_data" "llm_bench_setup" {
  triggers_replace = [local.llm_bench_files_sha, module.llm_bench.generation]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude README.md -C ${local.llm_bench_dir} -cf - . \
        | ${local.llm_bench_ssh} 'pct exec ${module.llm_bench.vmid} -- sh -c "rm -rf /root/llm-bench && mkdir -p /root/llm-bench && tar -xf - -C /root/llm-bench"'
      ${local.llm_bench_ssh} 'pct exec ${module.llm_bench.vmid} -- bash /root/llm-bench/setup.sh'
    EOT
  }
}
