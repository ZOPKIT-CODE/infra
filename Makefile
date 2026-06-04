# =============================================================================
# Zopkit Suite — deploy/Makefile
#
# Operator convenience wrapper around Terraform, Docker/ECR, and Helm for the
# EKS-hosted suite (wrapper / crm / fa). It composes with the rest of deploy/:
#   - terraform/                       (the IaC; outputs feed this Makefile)
#   - helm/zopkit-backend/             (the generic backend chart)
#   - helm/zopkit-backend/values-<app>.yaml          (committed base values)
#   - helm/zopkit-backend/values-<app>.generated.yaml (rendered by render-values)
#   - scripts/render-values.sh         (injects `terraform output -json app_wiring`)
#
# Per-app facts (kept in sync with terraform/locals.tf):
#   app      backend build context        ECR repo key (ecr_repository_urls[...])
#   wrapper  ../backend                    wrapper-backend
#   crm      ../../b2b-crm/server          crm-backend
#   fa       ../../finance-accounting      fa-backend
#
# Quick start:
#   make init bootstrap            # init + create VPC/EKS so k8s/helm providers auth
#   make apply                     # create the remaining infra (incl. cluster addons)
#   make kubeconfig                # point kubectl at the new cluster
#   # (populate Secrets Manager secrets zopkit/prod/<app> + the valkey secret here)
#   make login-ecr
#   make build-wrapper push-wrapper TAG=$(git rev-parse --short HEAD)
#   make render-values             # renders values-<app>.generated.yaml for all apps
#   make deploy-all TAG=$(git rev-parse --short HEAD)
# =============================================================================

# --- Configuration -----------------------------------------------------------
# Image tag applied to every build/push/deploy. Override per-invocation, e.g.
#   make build-wrapper push-wrapper deploy-wrapper TAG=abc123
TAG          ?= latest

# Terraform lives in deploy/terraform; -chdir keeps state/plugins scoped there.
TF_DIR       := terraform
TF           := terraform -chdir=$(TF_DIR)

# Helm chart + namespace. NAMESPACE is read from Terraform when available so it
# tracks local.namespace; falls back to the pinned default if state isn't ready.
CHART        := ./helm/zopkit-backend
NAMESPACE    ?= zopkit-prod

# AWS region. Defaults from the AWS_REGION env var, else Terraform's region
# output (var.aws_region), else us-east-1 to match the provider default.
AWS_REGION   ?= $(or $(shell $(TF) output -raw region 2>/dev/null),us-east-1)

# Cluster name comes straight from Terraform state (module.eks.cluster_name).
CLUSTER_NAME ?= $(shell $(TF) output -raw cluster_name 2>/dev/null)

# All suite apps. Used by the *-all aggregate targets.
APPS         := wrapper crm fa

# Per-app backend build context (relative to deploy/) and ECR repo key.
DIR_wrapper  := ../backend
DIR_crm      := ../../b2b-crm/server
DIR_fa       := ../../finance-accounting

REPO_wrapper := wrapper-backend
REPO_crm     := crm-backend
REPO_fa      := fa-backend

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Phony declarations
# -----------------------------------------------------------------------------
.PHONY: help init plan apply bootstrap kubeconfig login-ecr \
        build-% push-% render-values deploy-% deploy-all \
        build-all push-all destroy

# -----------------------------------------------------------------------------
# help — list the common targets
# -----------------------------------------------------------------------------
help:
	@echo "Zopkit deploy targets (vars: TAG=$(TAG) AWS_REGION=$(AWS_REGION) NAMESPACE=$(NAMESPACE)):"
	@echo "  init             terraform init"
	@echo "  bootstrap        apply only module.vpc + module.eks (so k8s/helm providers auth)"
	@echo "  plan             terraform plan"
	@echo "  apply            terraform apply (full stack incl. cluster addons)"
	@echo "  kubeconfig       aws eks update-kubeconfig for the new cluster"
	@echo "  login-ecr        docker login to the account ECR registry"
	@echo "  build-<app>      docker build one app   (app: $(APPS))"
	@echo "  push-<app>       docker push one app to ECR"
	@echo "  build-all        build every app"
	@echo "  push-all         push every app"
	@echo "  render-values    run scripts/render-values.sh for every app -> values-<app>.generated.yaml"
	@echo "  deploy-<app>     helm upgrade --install one app"
	@echo "  deploy-all       deploy every app"
	@echo "  destroy          terraform destroy (DANGER)"

# =============================================================================
# Terraform
# =============================================================================

# init — download providers/modules and configure the backend.
init:
	$(TF) init

# plan — preview changes against the current state.
plan:
	$(TF) plan

# apply — create/update the full stack. Run AFTER `bootstrap` on a fresh stack.
# The ClusterSecretStore (kubernetes_manifest) may need a second `make apply`
# once the External Secrets CRDs exist (see README "Apply order").
apply:
	$(TF) apply

# bootstrap — first apply on a clean stack: stand up the network + cluster ONLY,
# so the kubernetes/helm providers (wired to the EKS module) can authenticate on
# the subsequent full `make apply`.
bootstrap:
	$(TF) apply -target=module.vpc -target=module.eks

# =============================================================================
# Cluster access
# =============================================================================

# kubeconfig — merge the cluster's context into ~/.kube/config so kubectl/helm
# can reach it. Cluster name + region are read from Terraform outputs.
kubeconfig:
	@test -n "$(CLUSTER_NAME)" || { echo "ERROR: cluster_name not in TF outputs; run 'make apply' first."; exit 1; }
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)

# =============================================================================
# Container images (Docker + ECR)
# =============================================================================

# login-ecr — authenticate Docker against this account's private ECR registry in
# AWS_REGION. Derives the registry host from the caller's account id.
login-ecr:
	@account=$$(aws sts get-caller-identity --query Account --output text); \
	registry=$$account.dkr.ecr.$(AWS_REGION).amazonaws.com; \
	echo "Logging in to $$registry"; \
	aws ecr get-login-password --region $(AWS_REGION) \
	  | docker login --username AWS --password-stdin $$registry

# _ecr_url — helper: print the repository_url for an ECR repo key, pulled from
# `terraform output -json ecr_repository_urls`. Usage: $(call _ecr_url,wrapper-backend)
# Requires jq.
_ecr_url = $(shell $(TF) output -json ecr_repository_urls 2>/dev/null | jq -r '.["$(1)"]')

# build-<app> — build the app's backend image and tag it with the ECR repo URL:TAG.
# Pattern target; $* is the app name (wrapper|crm|fa). DIR_/REPO_ maps above pick
# the build context and ECR repo key. Linux/amd64 platform pinned for EKS nodes.
build-%:
	@app=$*; \
	dir=$(DIR_$*); \
	repo_key=$(REPO_$*); \
	url=$$($(TF) output -json ecr_repository_urls | jq -r --arg k "$$repo_key" '.[$$k]'); \
	test -n "$$url" -a "$$url" != "null" || { echo "ERROR: no ECR url for $$repo_key (run terraform apply / ecr)"; exit 1; }; \
	test -n "$$dir" || { echo "ERROR: unknown app '$$app' (expected one of: $(APPS))"; exit 1; }; \
	echo "Building $$app from $$dir -> $$url:$(TAG)"; \
	docker build --platform linux/amd64 -t $$url:$(TAG) $$dir

# push-<app> — push the previously-built $url:TAG to ECR. Run `login-ecr` first.
push-%:
	@app=$*; \
	repo_key=$(REPO_$*); \
	url=$$($(TF) output -json ecr_repository_urls | jq -r --arg k "$$repo_key" '.[$$k]'); \
	test -n "$$url" -a "$$url" != "null" || { echo "ERROR: no ECR url for $$repo_key"; exit 1; }; \
	echo "Pushing $$url:$(TAG)"; \
	docker push $$url:$(TAG)

# build-all / push-all — fan out over every app (sequential; ECR tags are IMMUTABLE).
build-all: $(addprefix build-,$(APPS))
push-all:  $(addprefix push-,$(APPS))

# =============================================================================
# Helm rendering + deploy
# =============================================================================

# render-values — produce values-<app>.generated.yaml for every app by merging
# `terraform output -json app_wiring` onto the committed values-<app>.yaml.
# Delegates to scripts/render-values.sh (needs yq + jq). Passes TAG through so
# the generated image.tag matches what we built/pushed.
render-values:
	@for app in $(APPS); do \
	  echo "Rendering values for $$app (tag $(TAG))"; \
	  scripts/render-values.sh $$app $(TAG); \
	done

# deploy-<app> — install/upgrade one app's release. Prefers the rendered
# values-<app>.generated.yaml (from render-values); falls back to the committed
# base values-<app>.yaml if it hasn't been rendered yet. --set image.tag pins the
# image regardless. autoscaling.enabled is taken from the values file ONLY: crm/fa
# stay false there (their outbox pollers/crons have no leader election) — never
# override it on the command line.
deploy-%:
	@app=$*; \
	test -n "$(DIR_$*)" || { echo "ERROR: unknown app '$$app' (expected one of: $(APPS))"; exit 1; }; \
	gen=$(CHART)/values-$$app.generated.yaml; \
	if [ ! -f "$$gen" ]; then \
	  echo "ERROR: $$gen not found. Run 'make render-values' first — the committed base"; \
	  echo "       values-$$app.yaml carries REPLACED_BY_TF placeholders (serviceAccount.roleArn,"; \
	  echo "       ingress.certArn) and an empty env, which deploy a broken release."; \
	  exit 1; \
	fi; \
	echo "Deploying $$app from $$gen (image.tag=$(TAG)) into ns $(NAMESPACE)"; \
	helm upgrade --install $$app $(CHART) \
	  -f $$gen \
	  --namespace $(NAMESPACE) \
	  --set image.tag=$(TAG) \
	  --atomic --wait --timeout 10m

# deploy-all — deploy every app (wrapper first; crm/fa stay single-replica).
deploy-all: $(addprefix deploy-,$(APPS))

# =============================================================================
# Teardown
# =============================================================================

# destroy — tear the whole stack down. DANGER: deletes the cluster, data buckets,
# ElastiCache, Cognito pool, etc. Uninstall Helm releases first if you want the
# ALB/external-dns records cleaned up gracefully (see README "Teardown order").
destroy:
	$(TF) destroy
