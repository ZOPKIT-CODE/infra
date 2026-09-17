# =============================================================================
# Zopkit Suite — ECS Fargate stack Makefile
#
# Wraps the operator workflow:
#   init / plan / apply    terraform lifecycle (per-environment directory)
#   login-ecr              docker login to the account ECR registry
#   build-<app> push-<app> build + push wrapper|crm|fa images to ECR
#   deploy-<svc>           force a fresh ECS deployment for a service
#   migrate-<app>          notes on operator-run DB migrations (does NOT auto-run)
#
# Override on the CLI, e.g.:
#   make plan ENV=prod
#   make push-wrapper TAG=$(git rev-parse --short HEAD)
# =============================================================================

# --- Tunables --------------------------------------------------------------
# ENV selects the environment DIRECTORY. There is no terraform workspace any
# more and no -var-file: environments/<env>/terraform.tfvars auto-loads.
ENV         ?= staging
TF_DIR      := environments/$(ENV)
AWS_REGION  ?= us-east-1
TAG         ?= latest

# Where the application repos are checked out, relative to this file. They are
# siblings of this repo, not children of it — this Makefile used to live inside
# the wrapper repo and its build contexts were relative to that.
REPOS_ROOT  ?= ../../..

# Account id + ECR registry host (resolved from your current AWS creds).
ACCOUNT_ID  := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY = $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

# ECS cluster name is "${project}-${environment}", so it follows ENV.
CLUSTER     ?= zopkit-$(ENV)

# App -> ECR repo mapping.
#   wrapper -> wrapper-backend, crm -> crm-backend, fa -> fa-backend
REPO_wrapper = wrapper-backend
REPO_crm     = crm-backend
REPO_fa      = fa-backend

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- Terraform lifecycle ---------------------------------------------------
.PHONY: init
init: ## terraform init for ENV (default staging)
	terraform -chdir=$(TF_DIR) init

.PHONY: plan
plan: ## terraform plan for ENV
	terraform -chdir=$(TF_DIR) plan

.PHONY: apply
apply: ## terraform apply for ENV
	terraform -chdir=$(TF_DIR) apply

.PHONY: destroy
destroy: ## terraform destroy for ENV (Supabase + ECR persist)
	terraform -chdir=$(TF_DIR) destroy

# --- ECR + images ----------------------------------------------------------
.PHONY: login-ecr
login-ecr: ## docker login to the account ECR registry
	aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin $(ECR_REGISTRY)

# build-<app>: build the image locally and tag it for ECR.
.PHONY: build-wrapper build-crm build-fa
build-wrapper: ## Build the wrapper-backend image
	docker build --platform linux/amd64 -t $(ECR_REGISTRY)/$(REPO_wrapper):$(TAG) $(REPOS_ROOT)/wrapper/backend
build-crm: ## Build the crm-backend image (context: b2b-crm/server)
	docker build --platform linux/amd64 -t $(ECR_REGISTRY)/$(REPO_crm):$(TAG) $(REPOS_ROOT)/b2b-crm/server
build-fa: ## Build the fa-backend image (context: finance-accounting root)
	docker build --platform linux/amd64 -t $(ECR_REGISTRY)/$(REPO_fa):$(TAG) $(REPOS_ROOT)/finance-accounting

# push-<app>: push the tagged image to ECR (run login-ecr + build-<app> first).
.PHONY: push-wrapper push-crm push-fa
push-wrapper: ## Push the wrapper-backend image to ECR
	docker push $(ECR_REGISTRY)/$(REPO_wrapper):$(TAG)
push-crm: ## Push the crm-backend image to ECR
	docker push $(ECR_REGISTRY)/$(REPO_crm):$(TAG)
push-fa: ## Push the fa-backend image to ECR
	docker push $(ECR_REGISTRY)/$(REPO_fa):$(TAG)

# --- Service rollout -------------------------------------------------------
# deploy-<svc>: force ECS to pull the current image tag / re-read secrets.
.PHONY: deploy-wrapper-web deploy-crm-web deploy-fa-web deploy-fa-consumer
deploy-wrapper-web: ## Force a new deployment of wrapper-web
	aws ecs update-service --cluster $(CLUSTER) --service $(CLUSTER)-wrapper-web --force-new-deployment --region $(AWS_REGION)
deploy-crm-web: ## Force a new deployment of crm-web
	aws ecs update-service --cluster $(CLUSTER) --service $(CLUSTER)-crm-web --force-new-deployment --region $(AWS_REGION)
deploy-fa-web: ## Force a new deployment of fa-web
	aws ecs update-service --cluster $(CLUSTER) --service $(CLUSTER)-fa-web --force-new-deployment --region $(AWS_REGION)
deploy-fa-consumer: ## Force a new deployment of fa-consumer
	aws ecs update-service --cluster $(CLUSTER) --service $(CLUSTER)-fa-consumer --force-new-deployment --region $(AWS_REGION)

# --- Migrations (operator-run; NEVER on container start) -------------------
# These targets are NOTES only — migrations are intentionally not automated.
# Run them from each backend repo against the env's DATABASE_URL, then deploy.
.PHONY: migrate-wrapper migrate-crm migrate-fa
migrate-wrapper: ## NOTE: run wrapper migrations operator-side (does not auto-run)
	@echo "Run wrapper migrations from the wrapper backend repo, e.g.:  pnpm db:migrate"
	@echo "Or as a one-off Fargate task — see the commented 'aws ecs run-task' example in README.md (Step 4)."
migrate-crm: ## NOTE: run CRM migrations operator-side (does not auto-run)
	@echo "Run CRM migrations from the CRM backend repo, e.g.:  pnpm db:migrate"
	@echo "Or as a one-off Fargate task — see the commented 'aws ecs run-task' example in README.md (Step 4)."
migrate-fa: ## NOTE: run FA migrations operator-side (does not auto-run)
	@echo "Run FA migrations from the FA backend repo, e.g.:  pnpm db:migrate"
	@echo "Or as a one-off Fargate task — see the commented 'aws ecs run-task' example in README.md (Step 4)."
