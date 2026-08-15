SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= proofline
KUBE_CONTEXT ?= kind-$(CLUSTER_NAME)
REGISTRY     ?= localhost:5001
IMAGE        ?= $(REGISTRY)/proofline/app
TAG          ?= dev
ENV          ?= dev
PROMETHEUS   ?= http://localhost:30090
PROBE_PORT   ?= 18080

KUBECTL := kubectl --context $(KUBE_CONTEXT)
NS       = proofline-$(ENV)

ifneq (,$(findstring xterm,$(TERM)))
	BOLD  := $(shell tput bold)
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

.PHONY: cluster
cluster: ## Create the kind cluster and local registry
	$(call banner,creating cluster)
	@./hack/kind-with-registry.sh

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

.PHONY: ansible
ansible: ## Configure the server fleet with Ansible
	$(call banner,ansible: configuring the fleet)
	@cd ansible && ansible-galaxy collection install -r requirements.yml
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
build: ## Build and push the application image
	$(call banner,building $(IMAGE):$(TAG))
	@docker build -t $(IMAGE):$(TAG) ./app
	@docker push $(IMAGE):$(TAG)

.PHONY: deploy
deploy: ## Deploy to ENV (default dev), without probing
	$(call banner,deploying to $(ENV))
	@cd k8s/overlays/$(ENV) && kustomize edit set image proofline/app=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/$(ENV)
	@$(KUBECTL) rollout status deployment/proofline -n $(NS) --timeout=300s

.PHONY: prove
prove: ## Deploy to ENV and prove the rollout dropped no requests
	$(call banner,deploying to $(ENV) with the prober running)
	@mkdir -p reports/$(ENV)
	@cd k8s/overlays/$(ENV) && kustomize edit set image proofline/app=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/$(ENV)
	@./hack/probe-rollout.sh $(KUBE_CONTEXT) $(NS) $(PROBE_PORT) reports/$(ENV)/probe.json

.PHONY: break
break: ## Deploy WITHOUT the zero-downtime settings; the prober should fail
	$(call banner,deploying the deliberately unsafe overlay)
	@echo "maxUnavailable 25%, no preStop hook, no drain, 60s readiness period."
	@echo "If the prober passes this, the prober is broken -- that is the point."
	@echo ""
	@mkdir -p reports/broken
	@cd k8s/overlays/broken && kustomize edit set image proofline/app=$(IMAGE):$(TAG)
	@$(KUBECTL) apply -k k8s/overlays/broken
	@-./hack/probe-rollout.sh $(KUBE_CONTEXT) proofline-dev $(PROBE_PORT) reports/broken/probe.json
	@echo ""
	@echo "$(BOLD)restoring the safe overlay$(RESET)"
	@$(KUBECTL) apply -k k8s/overlays/dev
	@$(KUBECTL) rollout status deployment/proofline -n proofline-dev --timeout=300s

.PHONY: gate
gate: ## Ask the SLO gate whether ENV earned promotion
	$(call banner,slo gate: $(ENV))
	@mkdir -p reports/$(ENV)
	@python3 slo/gate.py --prometheus $(PROMETHEUS) --environment $(ENV) \
		--report reports/$(ENV)/gate.json

.PHONY: burn
burn: ## Inject errors into dev, then watch the SLO gate block promotion
	$(call banner,injecting a 20%% error rate into dev)
	@$(KUBECTL) set env deployment/proofline -n proofline-dev APP_ERROR_RATE=0.2
	@$(KUBECTL) rollout status deployment/proofline -n proofline-dev --timeout=300s
	$(call banner,generating traffic so the gate has something to judge)
	@./hack/probe-rollout.sh $(KUBE_CONTEXT) proofline-dev $(PROBE_PORT) \
		reports/dev/burn-probe.json 120 || true
	$(call banner,asking the gate)
	@-python3 slo/gate.py --prometheus $(PROMETHEUS) --environment dev \
		--report reports/dev/burn-gate.json
	@echo ""
	@echo "$(BOLD)removing the injected errors$(RESET)"
	@$(KUBECTL) set env deployment/proofline -n proofline-dev APP_ERROR_RATE-
	@$(KUBECTL) rollout status deployment/proofline -n proofline-dev --timeout=300s

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
