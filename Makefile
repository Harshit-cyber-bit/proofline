SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# pip drops console scripts (ansible-lint, pytest, ruff) into ~/.local/bin,
# which a fresh login shell does not always have on PATH. Adding it here means
# `make lint-ansible` works without anyone having to remember to fix PATH.
export PATH := $(HOME)/.local/bin:$(PATH)

CLUSTER_NAME ?= proofline
KUBE_CONTEXT ?= kind-$(CLUSTER_NAME)
REGISTRY     ?= localhost:5001
IMAGE        ?= $(REGISTRY)/proofline/app
TAG          ?= dev

# The name kustomize matches on when overriding the image. Must equal the image
# written in k8s/base/deployment.yaml, or the override silently does nothing and
# the base default deploys instead.
IMAGE_NAME   ?= $(REGISTRY)/proofline/app
ENV          ?= dev
PROMETHEUS   ?= http://localhost:30090

# Fixed NodePorts, mapped to the host by hack/kind-with-registry.sh. The prober
# hits these so it goes through kube-proxy -- the path real traffic takes --
# rather than a port-forward, which tunnels to a single pod and turns any
# rollout into a fake outage.
NODEPORT_dev     := 30080
NODEPORT_staging := 30081
NODEPORT_prod    := 30082
PROBE_PORT        = $(NODEPORT_$(ENV))

# Latency ceiling for a rollout, in milliseconds. A healthy rollout here sits
# around 15ms at p99; a rollout that takes every pod down at once holds requests
# for one to two seconds before they succeed, because kube-proxy has no endpoint
# to send them to and the client keeps retrying the SYN. Without this ceiling
# that outage is invisible -- the requests are slow, not failed.
PROBE_MAX_P99 ?= 1000

KUBECTL := kubectl --context $(KUBE_CONTEXT)
NS       = proofline-$(ENV)

ifneq (,$(findstring xterm,$(TERM)))
	BOLD  := $(shell tput bold)
	RED   := $(shell tput setaf 1)
	GREEN := $(shell tput setaf 2)
	RESET := $(shell tput sgr0)
endif

define banner
	@echo ""
	@echo "$(BOLD)==> $(1)$(RESET)"
endef

##@ Everything

.PHONY: up
up: cluster namespaces terraform-local build deploy ## Stand the whole local stack up
	$(call banner,stack ready)
	@echo "  make prove      # deploy again and prove no requests were dropped"
	@echo "  make break      # deploy without the safety settings and watch it fail"
	@echo "  make burn       # inject errors and watch the SLO gate block promotion"
	@echo "  make grafana    # http://localhost:30300  (admin / proofline)"

.PHONY: down
down: ## Tear everything down
	$(call banner,destroying local infrastructure)
	-@cd terraform/local && terraform destroy -auto-approve
	-@docker compose -f jenkins/docker-compose.yml down -v
	@kind delete cluster --name $(CLUSTER_NAME)
	-@docker rm -f kind-registry 2>/dev/null || true

##@ Infrastructure

.PHONY: check-docker
check-docker: ## Verify the Docker daemon is reachable as this user
	@docker info >/dev/null 2>&1 || { \
		echo ""; \
		echo "$(BOLD)Cannot talk to the Docker daemon as $$(id -un).$(RESET)"; \
		echo ""; \
		if id -nG "$$(id -un)" | grep -qw docker; then \
			echo "You ARE in the docker group, but this shell started before that"; \
			echo "was true. Group membership only applies to new login shells."; \
			echo ""; \
			echo "  Fix, in order of preference:"; \
			echo "    exec newgrp docker          # this shell, right now"; \
			echo "    wsl --shutdown              # from Windows, then reopen Ubuntu"; \
		else \
			echo "  sudo usermod -aG docker $$(id -un)"; \
			echo "  exec newgrp docker"; \
		fi; \
		echo ""; \
		echo "  Also check the daemon is running:"; \
		echo "    sudo systemctl start docker    # or: sudo service docker start"; \
		echo ""; \
		exit 1; \
	}
	@echo "    docker ok ($$(docker version --format '{{.Server.Version}}' 2>/dev/null))"

.PHONY: cluster
cluster: check-docker ## Create the kind cluster and local registry
	$(call banner,creating cluster)
	@./hack/kind-with-registry.sh
	@# A cluster created before the NodePort mappings were added cannot expose
	@# them, and the failure surfaces later as "service not reachable".
	@docker inspect proofline-control-plane \
		--format '{{range $$p, $$c := .NetworkSettings.Ports}}{{$$p}} {{end}}' 2>/dev/null \
		| grep -q '30080/tcp' \
		|| { echo ""; \
		     echo "$(BOLD)This cluster predates the NodePort mappings.$(RESET)"; \
		     echo "Recreate it:  make down && make cluster"; \
		     echo ""; exit 1; }

.PHONY: namespaces
namespaces: ## Create the environment namespaces
	@for e in dev staging prod; do \
		$(KUBECTL) create namespace proofline-$$e --dry-run=client -o yaml | $(KUBECTL) apply -f - ; \
	done

.PHONY: terraform-local
terraform-local: ## Provision the local fleet and monitoring stack with Terraform
	$(call banner,terraform: local stack)
	@cd terraform/local && terraform init -input=false && terraform apply -auto-approve
	@$(KUBECTL) apply -f slo/rules/proofline-slo-rules.yaml
	@$(KUBECTL) apply -k k8s/monitoring

.PHONY: fleet-check
fleet-check: ## Diagnose why the Ansible fleet containers will not boot
	$(call banner,fleet: why systemd is not staying up)
	@./hack/fleet-check.sh

.PHONY: inventory-check
inventory-check: ## Prove the dynamic inventory resolves to the fleet, not localhost
	$(call banner,ansible inventory)
	@./hack/inventory-check.sh

.PHONY: ansible
ansible: ## Configure the server fleet with Ansible
	$(call banner,ansible: configuring the fleet)
	@# Fail here with something useful rather than inside the dynamic inventory,
	@# which reports a dead fleet as "no hosts matched" -- true, and useless.
	@running=$$(docker ps --filter name=proofline-app --filter status=running -q | wc -l); \
		if [ "$$running" -eq 0 ]; then \
			echo "  $(RED)no fleet containers are running.$(RESET)"; \
			echo "  The dynamic inventory would report 'no hosts matched', which is"; \
			echo "  true and tells you nothing. Find out why instead:"; \
			echo ""; \
			echo "      make fleet-check"; \
			exit 1; \
		fi; \
		echo "    $$running fleet host(s) up"
	@cd ansible && ansible-galaxy collection install -r requirements.yml
	@# A broken inventory is a WARNING in Ansible, not an error: it falls back
	@# to the implicit localhost and runs anyway. Turn that into an exit code
	@# before a playbook configures the wrong machine.
	@./hack/inventory-check.sh
	@cd ansible && ansible-playbook site.yml

.PHONY: ansible-idempotence
ansible-idempotence: ## Run the playbook twice and fail if the second run changes anything
	$(call banner,ansible: idempotence check)
	@cd ansible && ansible-playbook site.yml >/dev/null
	@cd ansible && ansible-playbook site.yml | tee /tmp/proofline-ansible-2nd.log | tail -20
	@if grep -qE 'changed=[1-9]' /tmp/proofline-ansible-2nd.log; then \
		echo "$(BOLD)FAIL$(RESET) the second run changed something; the playbook is not idempotent"; \
		exit 1; \
	else \
		echo "$(BOLD)PASS$(RESET) the second run changed nothing"; \
	fi

##@ Delivery

.PHONY: build
build: check-docker ## Build and push the application image
	$(call banner,building $(IMAGE):$(TAG))
	@docker build -t $(IMAGE):$(TAG) ./app
	@docker push $(IMAGE):$(TAG)

.PHONY: deploy
deploy: ## Deploy to ENV (default dev), without probing
	$(call banner,deploying to $(ENV))
	@cd k8s/overlays/$(ENV) && kustomize edit set image $(IMAGE_NAME)=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/$(ENV)
	@$(KUBECTL) rollout status deployment/proofline -n $(NS) --timeout=300s

.PHONY: prove
prove: ## Deploy to ENV and prove the rollout dropped no requests
	$(call banner,deploying to $(ENV) with the prober running)
	@mkdir -p reports/$(ENV)
	@cd k8s/overlays/$(ENV) && kustomize edit set image $(IMAGE_NAME)=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/$(ENV)
	@MAX_P99_MS=$(PROBE_MAX_P99) ./hack/probe-rollout.sh $(KUBE_CONTEXT) $(NS) $(PROBE_PORT) reports/$(ENV)/probe.json

.PHONY: break
break: ## Deploy WITHOUT the zero-downtime settings; the prober should fail
	$(call banner,deploying the deliberately unsafe overlay)
	@echo "maxUnavailable 100%, no preStop hook, no drain, 60s readiness period."
	@echo "If the prober passes this, the prober is broken -- that is the point."
	@echo ""
	@mkdir -p reports/broken
	@cd k8s/overlays/broken && kustomize edit set image $(IMAGE_NAME)=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/broken
	@-MAX_P99_MS=$(PROBE_MAX_P99) ./hack/probe-rollout.sh $(KUBE_CONTEXT) proofline-dev $(NODEPORT_dev) reports/broken/probe.json
	@echo ""
	@$(MAKE) --no-print-directory restore

.PHONY: restore
restore: ## Put dev back on the safe overlay (also run automatically after `make break`)
	$(call banner,restoring the safe overlay)
	@# Set the image here too. Skipping it was a real bug: on a freshly cloned
	@# repo the overlay has no image override recorded, so the apply fell back to
	@# the base default and the pod tried to pull from Docker Hub.
	@cd k8s/overlays/dev && kustomize edit set image $(IMAGE_NAME)=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/dev
	@# Cleanup, not measurement -- a stalled restore must report why rather than
	@# just failing with "timed out waiting for the condition", which says
	@# nothing about the cause.
	@$(KUBECTL) rollout status deployment/proofline -n proofline-dev --timeout=180s \
		|| { \
			echo ""; \
			echo "$(BOLD)The restore did not converge. Diagnosis:$(RESET)"; \
			echo ""; \
			echo "--- pods ---"; \
			$(KUBECTL) get pods -n proofline-dev -o wide; \
			echo ""; \
			echo "--- not-ready containers ---"; \
			$(KUBECTL) get pods -n proofline-dev \
				-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}ready={.ready} restarts={.restartCount} {.state}{end}{"\n"}{end}'; \
			echo ""; \
			echo "--- recent events ---"; \
			$(KUBECTL) get events -n proofline-dev \
				--sort-by=.lastTimestamp | tail -20; \
			echo ""; \
			echo "--- rollout ---"; \
			$(KUBECTL) describe deployment proofline -n proofline-dev \
				| sed -n '/Conditions:/,/Events:/p'; \
			echo ""; \
			echo "Most likely causes, in order:"; \
			echo "  1. Not enough memory for surge pods. Raise WslMemory, or"; \
			echo "     scale down:  kubectl scale deploy/proofline -n proofline-dev --replicas=1"; \
			echo "  2. A pod stuck Terminating from the broken overlay:"; \
			echo "     kubectl delete pod -n proofline-dev --field-selector=status.phase!=Running --force"; \
			echo "  3. ImagePullBackOff above? The image is not in the local"; \
			echo "     registry, or the override did not apply:"; \
			echo "     make build"; \
			echo "     kubectl get deploy proofline -n proofline-dev \\"; \
			echo "       -o jsonpath='{.spec.template.spec.containers[0].image}'"; \
			echo "     It must start with $(REGISTRY)/ -- a bare name means Docker Hub."; \
			echo ""; \
			echo "Then re-run:  make restore"; \
			exit 1; \
		}
	@echo "    dev is back on the safe overlay"

.PHONY: gate
gate: ## Ask the SLO gate whether ENV earned promotion
	$(call banner,slo gate: $(ENV))
	@mkdir -p reports/$(ENV)
	@python3 slo/gate.py --prometheus $(PROMETHEUS) --environment $(ENV) \
		--report reports/$(ENV)/gate.json

.PHONY: gate-explain
gate-explain: ## Ask the gate, and show the traffic breakdown behind its answer
	$(call banner,slo gate: $(ENV) -- explained)
	@mkdir -p reports/$(ENV)
	@-python3 slo/gate.py --prometheus $(PROMETHEUS) --environment $(ENV) \
		--explain --report reports/$(ENV)/gate.json

.PHONY: burn
burn: ## Inject errors into dev, then watch the SLO gate block promotion
	$(call banner,injecting a 20%% error rate into dev)
	@$(KUBECTL) set env deployment/proofline -n proofline-dev APP_ERROR_RATE=0.2
	@$(KUBECTL) rollout status deployment/proofline -n proofline-dev --timeout=300s
	$(call banner,generating traffic so the gate has something to judge)
	@./hack/probe-rollout.sh $(KUBE_CONTEXT) proofline-dev $(NODEPORT_dev) \
		reports/dev/burn-probe.json 120 || true
	$(call banner,asking the gate)
	@# The gate is expected to BLOCK. If it promotes a deployment the prober
	@# just failed, that is a bug in the gate, not a passing test -- so this
	@# target fails, loudly, and prints the traffic breakdown that explains it.
	@python3 slo/gate.py --prometheus $(PROMETHEUS) --environment dev \
		--explain --report reports/dev/burn-gate.json; \
		rc=$$?; \
		echo ""; \
		echo "$(BOLD)removing the injected errors$(RESET)"; \
		$(KUBECTL) set env deployment/proofline -n proofline-dev APP_ERROR_RATE- >/dev/null; \
		$(KUBECTL) rollout status deployment/proofline -n proofline-dev --timeout=300s; \
		echo ""; \
		if [ $$rc -eq 0 ]; then \
			echo "$(RED)the gate promoted a deployment serving 20% errors.$(RESET)"; \
			echo ""; \
			echo "  The prober failed this same rollout. Two measurements of one"; \
			echo "  event disagreeing means one of them is wrong, and it is this one."; \
			echo "  Look at the breakdown above: if health-check traffic dominates"; \
			echo "  the denominator, real errors are being divided into the noise."; \
			exit 1; \
		fi; \
		echo "$(GREEN)the gate blocked promotion, which is the point.$(RESET)"

##@ Jenkins

.PHONY: jenkins
jenkins: ## Start the Jenkins controller (configured entirely from code)
	$(call banner,starting jenkins on http://localhost:8081)
	@docker compose -f jenkins/docker-compose.yml up -d --build
	@echo "admin / proofline"

.PHONY: jenkins-logs
jenkins-logs: ## Tail the Jenkins log
	@docker compose -f jenkins/docker-compose.yml logs -f

##@ Verification

.PHONY: verify
verify: test validate lint-ansible ## Run everything that can be checked without a cluster
	$(call banner,all offline checks passed)

.PHONY: test
test: ## Run the Python test suites
	$(call banner,unit tests)
	@python3 -m pytest prober/tests slo/tests -q

.PHONY: validate
validate: ## Schema-validate manifests, check overlays, parse Terraform
	$(call banner,manifest and terraform validation)
	@python3 hack/validate.py

.PHONY: lint-ansible
lint-ansible: ## Lint and syntax-check the Ansible
	$(call banner,ansible lint)
	@cd ansible && ansible-lint site.yml roles/
	@cd ansible && ansible-playbook site.yml --syntax-check -i localhost,

.PHONY: fmt
fmt: ## Format Terraform
	@terraform fmt -recursive terraform/

##@ Observability

.PHONY: prom-check
prom-check: ## Confirm Prometheus is scraping the app before trusting the gate
	$(call banner,prometheus scrape check)
	@# A script, not an inline one-liner. The query contains braces and quotes
	@# that must be percent-encoded, and escaping them through make -> sh ->
	@# python is how you end up debugging your own quoting instead of the scrape.
	@python3 hack/prom-check.py --prometheus $(PROMETHEUS) --job proofline

.PHONY: grafana
grafana: ## Print the Grafana URL and credentials
	@echo "http://localhost:30300   admin / proofline"

.PHONY: prometheus
prometheus: ## Print the Prometheus URL
	@echo "$(PROMETHEUS)"

.PHONY: status
status: ## Show what is running
	@echo "$(BOLD)environments$(RESET)"
	@$(KUBECTL) get deploy,pod -n proofline-dev -n proofline-dev 2>/dev/null || true
	@for e in dev staging prod; do \
		echo ""; echo "$(BOLD)proofline-$$e$(RESET)"; \
		$(KUBECTL) get deploy,pod -n proofline-$$e 2>/dev/null || true; \
	done
	@echo ""
	@echo "$(BOLD)fleet$(RESET)"
	@docker ps --filter "label=proofline.role=app" --format "  {{.Names}}\t{{.Status}}"

##@ AWS (optional, costs money)

.PHONY: aws-plan
aws-plan: ## Plan the AWS reference stack against your own account
	@cd terraform/aws && terraform init -input=false && terraform plan

.PHONY: aws-apply
aws-apply: ## Apply the AWS stack (roughly $80/month -- see terraform/aws/main.tf)
	@cd terraform/aws && terraform apply

.PHONY: aws-destroy
aws-destroy: ## Destroy the AWS stack
	@cd terraform/aws && terraform destroy

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nproofline -- a delivery pipeline that proves its own claims\n\nUsage:\n  make $(BOLD)<target>$(RESET) [ENV=dev|staging|prod]\n"} \
		/^[a-zA-Z_0-9-]+:.*?##/ { printf "  $(BOLD)%-20s$(RESET) %s\n", $$1, $$2 } \
		/^##@/ { printf "\n%s\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
