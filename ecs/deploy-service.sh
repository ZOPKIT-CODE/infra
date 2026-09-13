#!/usr/bin/env bash
# =============================================================================
# deploy-service.sh — deploy ONE suite service to ECS Fargate, end to end.
#
#   Usage:  ./deploy-service.sh <service> [image_tag]
#   Example: ./deploy-service.sh wrapper-web            # tag = current git SHA
#            ./deploy-service.sh wrapper-web 1a2b3c4     # explicit tag
#
# Services: wrapper-web | crm-web | crm-worker | fa-web | fa-consumer
#
# What it does (the 6-step deploy unit from the playbook):
#   1. build   — docker build for linux/amd64 (Fargate is x86)
#   2. push    — to the service's ECR repo, IMMUTABLE git-SHA tag (never :latest)
#   3. migrate — run DB migrations as a one-off Fargate task (web services only)
#   4. release — record the tag in SSM (/<project>/<env>/deployed-tag/<svc>) + terraform apply
#                -target just this service (one-app-at-a-time, others untouched)
#   5. wait    — block until the ECS service reaches steady state
#   6. smoke   — hit the health endpoint (web services only)
#
# Rollback: re-run with a previous SHA  ->  ./deploy-service.sh wrapper-web <old-sha>
#
# Config: copy deploy.env.example -> deploy.env and fill it in (gitignored).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

# ---- load config -----------------------------------------------------------
[[ -f "$SCRIPT_DIR/deploy.env" ]] || { echo "✖ Missing $SCRIPT_DIR/deploy.env (copy deploy.env.example)"; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/deploy.env"

: "${AWS_REGION:?set in deploy.env}"
: "${AWS_ACCOUNT_ID:?set in deploy.env}"
: "${NAME_PREFIX:?set in deploy.env}"          # e.g. zopkit-prod  (= project-environment)
: "${WRAPPER_REPO:?set in deploy.env}"         # local path to the wrapper repo root
: "${TASK_SUBNETS:?set in deploy.env}"         # subnet ids for the migration task (PUBLIC if no NAT)
: "${TASK_SG:?set in deploy.env}"              # security group id for the migration task
TASK_ASSIGN_PUBLIC_IP="${TASK_ASSIGN_PUBLIC_IP:-DISABLED}"  # ENABLED for public-subnet/no-NAT setups

# ---- derive environment from NAME_PREFIX (e.g. zopkit-prod → prod) ----------
DEPLOY_ENV="${NAME_PREFIX#*-}"   # "prod" | "staging" | ...
case "$DEPLOY_ENV" in
  prod)
    TF_WORKSPACE="prod"
    TF_VARFILE="$TF_DIR/terraform.prod.tfvars"
    [[ -f "$TF_VARFILE" ]] || { echo "✖ Missing $TF_VARFILE — cannot deploy to prod without it"; exit 1; }
    ;;
  staging|*)
    TF_WORKSPACE="default"
    TF_VARFILE=""
    ;;
esac

SERVICE="${1:-}"
[[ -n "$SERVICE" ]] || { echo "Usage: $0 <wrapper-web|crm-web|crm-worker|fa-web|fa-consumer> [image_tag]"; exit 1; }

# ---- per-service config ----------------------------------------------------
# Each backend lives in its OWN repo; set REPO/DOCKERFILE/CONTEXT accordingly.
# migrate=true only for the service that owns its database schema (the *-web of
# each app). fa-consumer shares fa-web's DB, so it never migrates.
#
# The table itself lives in services.json — the SAME file .github/workflows/deploy.yml
# reads, so the two deploy paths cannot drift apart the way the duplicated bash
# `case` statements did. Per-service deploy.env overrides still win, for the local
# checkout path and for anything you need to poke at without editing the manifest.
MANIFEST="$SCRIPT_DIR/services.json"
[[ -f "$MANIFEST" ]] || { echo "✖ Missing $MANIFEST"; exit 1; }
command -v jq >/dev/null || { echo "✖ jq is required to read $MANIFEST (brew install jq)"; exit 1; }

svc_get() { jq -r --arg s "$SERVICE" --arg k "$1" '.services[$s][$k] // empty' "$MANIFEST"; }

jq -e --arg s "$SERVICE" '.services | has($s)' "$MANIFEST" >/dev/null || {
  echo "✖ Unknown service '$SERVICE'. Known: $(jq -r '.services | keys | join(" ")' "$MANIFEST")" >&2
  echo "  (Add it to $MANIFEST — that one entry wires up BOTH this script and CI.)" >&2
  exit 1
}

APP="$(svc_get app)"
ECR_REPO="$(svc_get ecr)"
UAPP="$(echo "$APP" | tr '[:lower:]' '[:upper:]')"

# Local checkout path: <APP>_REPO in deploy.env (WRAPPER_REPO / CRM_REPO / FA_REPO).
REPO_VAR="$(svc_get repo_env)"
REPO="${!REPO_VAR:-}"
[[ -n "$REPO" ]] || { echo "✖ Set $REPO_VAR in deploy.env (local checkout of $APP)"; exit 1; }

# deploy.env may override the build inputs per app, e.g. CRM_DOCKERFILE.
_df="${UAPP}_DOCKERFILE"; DOCKERFILE="${!_df:-$(svc_get dockerfile)}"
_ct="${UAPP}_TARGET";     TARGET="${!_ct:-$(svc_get target)}"
CONTEXT="$(svc_get context)"

# The deploy.env overrides below are keyed by APP (CRM_*, FA_*), but migrate and
# health are per-SERVICE: a headless worker shares its app's DB and has no ALB.
# So consult an override ONLY when the manifest says this service has that
# capability at all — otherwise crm-worker inherits CRM_MIGRATE_CMD and
# CRM_HEALTH_URL and would try to migrate, then smoke-test crm-web's endpoint.
MIGRATE="$(jq -r --arg s "$SERVICE" '.services[$s].migrate' "$MANIFEST")"
MIGRATE_CMD=''
if [[ "$MIGRATE" == "true" ]]; then
  _mc="${UAPP}_MIGRATE_CMD"
  MIGRATE_CMD="${!_mc:-$(jq -c --arg s "$SERVICE" '.services[$s].migrate_cmd' "$MANIFEST")}"
fi

# Smoke-test URL: explicit <APP>_HEALTH_URL from deploy.env wins; otherwise compose
# it from the manifest + ROOT_DOMAIN, so one entry serves staging and prod.
HEALTH_URL=''
_sub="$(svc_get api_subdomain)"; _path="$(svc_get health_path)"
if [[ -n "$_sub" && -n "$_path" ]]; then
  _hu="${UAPP}_HEALTH_URL"; HEALTH_URL="${!_hu:-}"
  if [[ -z "$HEALTH_URL" && -n "${ROOT_DOMAIN:-}" ]]; then
    HEALTH_URL="https://${_sub}.${ROOT_DOMAIN}${_path}"
  fi
  # This service HAS a health endpoint but we could not build a URL for it, so
  # step 6 would quietly skip — and a silently-skipped smoke test is how a broken
  # release gets reported as a success. Say so loudly instead.
  [[ -n "$HEALTH_URL" ]] || echo "⚠  $SERVICE declares a health endpoint but neither ${UAPP}_HEALTH_URL nor ROOT_DOMAIN is set in deploy.env — the smoke test will be SKIPPED." >&2
fi

TAG="${2:-$(cd "$REPO" && git rev-parse --short HEAD)}"
ECR_HOST="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
IMAGE="$ECR_HOST/$ECR_REPO:$TAG"
# Cluster is "${name_prefix}-ecs"; ECS service is "${name_prefix}-<service>".
CLUSTER="${ECS_CLUSTER:-$NAME_PREFIX-ecs}"
ECS_SERVICE="$NAME_PREFIX-$SERVICE"

echo "════════════════════════════════════════════════════════════════"
echo "  Deploy  $SERVICE"
echo "  repo    $REPO"
echo "  image   $IMAGE"
echo "  cluster $CLUSTER   service $ECS_SERVICE   migrate=$MIGRATE"
echo "════════════════════════════════════════════════════════════════"
read -r -p "Proceed? [y/N] " ok; [[ "$ok" == "y" || "$ok" == "Y" ]] || exit 0

# ---- 1+2. build & push -----------------------------------------------------
# Idempotent rerun: ECR tags are IMMUTABLE — if this tag already exists, the
# image is final; skip build+push instead of dying on the re-push (lets a
# deploy that failed at a later step be re-run with the same tag).
if aws ecr describe-images --repository-name "$ECR_REPO" --image-ids imageTag="$TAG"      --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "▶ [1/6+2/6] image $TAG already in ECR (immutable) — skipping build+push"
else
echo "▶ [1/6] docker build (linux/amd64)…"
# --target is omitted when the manifest has none: academy's Dockerfile ends in an
# unnamed stage (plain `FROM node:18-alpine`), and `--target ""` is an error.
BUILD_ARGS=(--platform linux/amd64 -f "$DOCKERFILE")
[[ -n "$TARGET" ]] && BUILD_ARGS+=(--target "$TARGET")
( cd "$REPO" && docker build "${BUILD_ARGS[@]}" -t "$IMAGE" "$CONTEXT" )

echo "▶ [2/6] push to ECR…"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_HOST"
docker push "$IMAGE"
fi

# ---- 3. release: record tag + terraform apply (registers the NEW task def) --
# Must run BEFORE migrate: ECS run-task cannot override a container image, so the
# migration task has to use a task definition that already points at the new image.
echo "▶ [3/6] record tag in SSM + terraform apply…"
# SSM is the single source of truth for the deployed tag — terraform's data
# source reads it during this apply and every later one (no stale git record).
aws ssm put-parameter \
  --name "/${NAME_PREFIX%%-*}/${NAME_PREFIX#*-}/deployed-tag/${SERVICE}" \
  --value "$TAG" --type String --overwrite --region "$AWS_REGION" > /dev/null
( cd "$TF_DIR" && \
  terraform workspace select "$TF_WORKSPACE" && \
  TF_ARGS=(-auto-approve -target="module.services[\"$SERVICE\"]") && \
  [[ -n "$TF_VARFILE" ]] && TF_ARGS+=(-var-file="$TF_VARFILE") || true && \
  terraform apply "${TF_ARGS[@]}" )

# ---- 4. migrate (web services only) — uses the new task def from step 3 -----
if [[ "$MIGRATE" == "true" ]]; then
  echo "▶ [4/6] run migrations as a one-off Fargate task…"
  TASKDEF="$(aws ecs describe-services --cluster "$CLUSTER" --services "$ECS_SERVICE" \
            --query 'services[0].taskDefinition' --output text --region "$AWS_REGION")"
  # No image override (ECS forbids it) — the task def already has the new image.
  OVERRIDES="{\"containerOverrides\":[{\"name\":\"$SERVICE\",\"command\":$MIGRATE_CMD}]}"
  TASK_ARN="$(aws ecs run-task --cluster "$CLUSTER" --launch-type FARGATE --region "$AWS_REGION" \
    --task-definition "$TASKDEF" --overrides "$OVERRIDES" \
    --network-configuration "awsvpcConfiguration={subnets=[$TASK_SUBNETS],securityGroups=[$TASK_SG],assignPublicIp=$TASK_ASSIGN_PUBLIC_IP}" \
    --query 'tasks[0].taskArn' --output text)"
  echo "  migration task: $TASK_ARN — waiting for it to stop…"
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$AWS_REGION"
  EXIT="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$AWS_REGION" \
          --query 'tasks[0].containers[0].exitCode' --output text)"
  [[ "$EXIT" == "0" ]] || { echo "✖ Migration task exited $EXIT — check CloudWatch logs. Aborting."; exit 1; }
  echo "  ✓ migrations applied (exit 0)"
else
  echo "▶ [4/6] migrate: skipped (shares another service's DB)"
fi

# ---- 5. wait for steady state ----------------------------------------------
echo "▶ [5/6] wait for ECS service to stabilise…"
aws ecs wait services-stable --cluster "$CLUSTER" --services "$ECS_SERVICE" --region "$AWS_REGION"
echo "  ✓ $ECS_SERVICE is stable"

# ---- 6. smoke test ---------------------------------------------------------
if [[ -n "$HEALTH_URL" ]]; then
  echo "▶ [6/6] smoke test $HEALTH_URL …"
  for i in $(seq 1 10); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" || true)"
    [[ "$code" == "200" ]] && { echo "  ✓ health 200"; break; }
    echo "  …($i) got $code, retrying"; sleep 6
    [[ "$i" == "10" ]] && { echo "✖ health never returned 200"; exit 1; }
  done
else
  echo "▶ [6/6] smoke test: skipped (headless worker — verify via CloudWatch logs / Sentry)"
fi

echo "✅ Deployed $SERVICE @ $TAG"
echo "   Verify in Sentry (errors + a trace) and CloudWatch logs."
echo "   Rollback: $0 $SERVICE <previous-sha>"
