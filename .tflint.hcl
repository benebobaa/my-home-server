# tflint for both stacks (make tflint). The bundled terraform ruleset with the
# "recommended" preset: unused declarations, missing types/descriptions,
# deprecated syntax. No provider rulesets exist for routeros/proxmox.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
}
