# One entrypoint for checking and converging the lab.
#
#   make check   static checks: format, validate, lint, rule files, secret scan.
#                No secrets needed; CI runs exactly this.
#   make plan    tofu plan on both stacks (needs the age key)
#   make drift   plan + Ansible --check --diff + Kubeletto overlay diff (needs the age key + lab access)
#   make fmt     rewrite Tofu files in canonical format
#
# Tools come from mise.toml (`mise install` once). Every tool runs through
# `mise exec` so the pinned versions win over whatever else is on PATH.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
X := mise exec --

STACKS      := network/routeros network/cloudflare proxmox/opentofu
MODULES     := inventory proxmox/opentofu/modules/lxc-guest
SHELL_FILES := $(shell git ls-files '*.sh' .githooks/pre-commit)
RULES       := services/monitoring/prometheus/rules/*.yml

.PHONY: check inventory fmt-check validate tflint shellcheck yamllint ansible-lint monitoring-config alert-contract dashboards dashboards-check dashboard-lint secrets-scan fmt plan drift

check: inventory fmt-check validate tflint shellcheck yamllint ansible-lint monitoring-config alert-contract dashboards-check dashboard-lint secrets-scan
	@echo "check: all passed"

# inventory/lab.yaml: unique IPs/VMIDs, IPs inside their VLAN, known nodes.
# Preconditions only run at plan time; the module has no providers or state,
# so it plans without secrets.
inventory:
	$(X) tofu -chdir=inventory init -backend=false -input=false -no-color >/dev/null
	$(X) tofu -chdir=inventory plan -input=false -no-color -lock=false >/dev/null && echo "inventory: lab.yaml OK"

fmt-check:
	$(X) tofu fmt -check -recursive $(STACKS) $(MODULES)

# -backend=false: validation needs the providers, not the state. The
# RouterOS provider insists on a username even to validate: give it a dummy.
validate:
	@for s in $(STACKS); do \
	  echo "validate: $$s"; \
	  $(X) tofu -chdir=$$s init -backend=false -input=false -no-color >/dev/null || exit 1; \
	  ROS_USERNAME=validate ROS_PASSWORD=validate $(X) tofu -chdir=$$s validate -no-color || exit 1; \
	done

tflint:
	@for s in $(STACKS) $(MODULES); do \
	  echo "tflint: $$s"; \
	  $(X) tflint --chdir=$$s --config="$(CURDIR)/.tflint.hcl" --init >/dev/null || exit 1; \
	  $(X) tflint --chdir=$$s --config="$(CURDIR)/.tflint.hcl" || exit 1; \
	done

shellcheck:
	$(X) shellcheck $(SHELL_FILES)

yamllint:
	$(X) yamllint --strict .

# Ansible aborts on non-blocking stdio in some shells: pipe through cat.
ansible-lint:
	cd ansible && $(X) ansible-lint proxmox-nodes.yml 2>&1 | cat; exit $${PIPESTATUS[0]}

# The same checks setup.sh / secrets.sh run in the CT before a reload.
monitoring-config:
	$(X) promtool check rules $(RULES)
	$(X) promtool test rules services/monitoring/prometheus/tests/*.test.yml
	$(X) promtool check config --syntax-only services/monitoring/prometheus/prometheus.yml
	sed -e 's/__TELEGRAM_CHAT_ID__/1/' \
	    -e 's|/etc/prometheus/alertmanager-templates/|$(CURDIR)/services/monitoring/alertmanager/|' \
	    services/monitoring/alertmanager/alertmanager.yml \
	  | $(X) amtool check-config /dev/stdin >/dev/null && echo "amtool: alertmanager.yml OK"
	$(X) amtool template render --template.glob='services/monitoring/alertmanager/*.tmpl' \
	  --template.text='{{ template "homelab.telegram" . }}' >/dev/null && echo "amtool: templates OK"
	python3 -c "import ast; ast.parse(open('services/monitoring/targets.py').read())" && echo "targets.py: syntax OK"

# ADR 0036 decision 5: every alert rule has summary, description, runbook_url
# (an anchor of docs/runbooks/alerts.md), dashboard_url (a generated board),
# and a severity label; rule names are unique.
alert-contract:
	$(X) uv run scripts/check-alert-contract.py

# Grafana boards are generated (ADR 0036): `make dashboards` rewrites the JSON;
# `make check` fails if the committed JSON differs from the generator, if a
# board breaks docs/standards/dashboards.md, or if the linter finds a problem.
dashboards:
	$(X) uv run scripts/dashboards/build.py

dashboards-check:
	$(X) uv run scripts/dashboards/build.py --check

# A folder name has a space ("Platform services"): read paths line by line.
# `|| exit 1`: a while loop reports only its last iteration's status, so
# without it a failing board in the middle would pass.
dashboard-lint:
	@find services/monitoring/grafana/dashboards -name '*.json' | sort | while IFS= read -r f; do \
	  $(X) dashboard-linter lint --config scripts/dashboards/lint.yml --strict "$$f" || exit 1; done
	@echo "dashboard-linter: all boards OK"

secrets-scan:
	$(X) gitleaks git --no-banner --redact .

fmt:
	$(X) tofu fmt -recursive $(STACKS) $(MODULES)

plan:
	@for s in $(STACKS); do \
	  echo "== $$s"; \
	  (cd $$s && $(X) sops exec-env secrets.sops.env 'tofu plan -no-color' 2>&1 \
	    | grep -vE 'field was lost|Schema development' \
	    | grep -E '^ *[#~+-] |Plan:|No changes|Error' || true); \
	done

drift: plan
	cd ansible && $(X) ansible-playbook proxmox-nodes.yml --check --diff 2>&1 | cat | sed -n '/PLAY RECAP/,$$p'
	@kr="$${KUBELETTO_REPO:-$$HOME/Documents/benelabs/kubeletto-home}"; \
	if [ -d "$$kr/infra/k8s/home" ]; then cd services/kubeletto && ./apply.sh drift; \
	else echo "kubeletto drift: no repo at $$kr, skipped"; fi
