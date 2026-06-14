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
case "$SERVICE" in
  wrapper-web)
    ECR_REPO="wrapper-backend"; REPO="$WRAPPER_REPO"
    DOCKERFILE="backend/Dockerfile"; CONTEXT="."; TARGET="production"
    MIGRATE=true;  MIGRATE_CMD='["node","dist/db/run-migrations.js"]'
    HEALTH_URL="${WRAPPER_HEALTH_URL:-}" ;;
  crm-web)
    ECR_REPO="crm-backend"; REPO="${CRM_REPO:?set CRM_REPO in deploy.env}"
    DOCKERFILE="${CRM_DOCKERFILE:-server/Dockerfile}"; CONTEXT="."; TARGET="${CRM_TARGET:-production}"
    MIGRATE=true;  MIGRATE_CMD="${CRM_MIGRATE_CMD:-[\"npm\",\"run\",\"db:migrate\"]}"  # VERIFY for CRM image
    HEALTH_URL="${CRM_HEALTH_URL:-}" ;;
  crm-worker)
    ECR_REPO="crm-backend"; REPO="${CRM_REPO:?set CRM_REPO in deploy.env}"
    DOCKERFILE="${CRM_DOCKERFILE:-server/Dockerfile}"; CONTEXT="."; TARGET="${CRM_TARGET:-production}"
    MIGRATE=false; MIGRATE_CMD=''   # shares crm-web's DB — crm-web's deploy migrates
    HEALTH_URL='' ;;                # headless (PROCESS_ROLE=worker), no ALB
  fa-web)
    ECR_REPO="fa-backend"; REPO="${FA_REPO:?set FA_REPO in deploy.env}"
    DOCKERFILE="${FA_DOCKERFILE:-server/Dockerfile}"; CONTEXT="."; TARGET="${FA_TARGET:-production}"
    MIGRATE=true;  MIGRATE_CMD="${FA_MIGRATE_CMD:-[\"npm\",\"run\",\"db:migrate\"]}"   # VERIFY for FA image
    HEALTH_URL="${FA_HEALTH_URL:-}" ;;
  fa-consumer)
    ECR_REPO="fa-backend"; REPO="${FA_REPO:?set FA_REPO in deploy.env}"
    DOCKERFILE="${FA_DOCKERFILE:-server/Dockerfile}"; CONTEXT="."; TARGET="${FA_TARGET:-production}"
    MIGRATE=false; MIGRATE_CMD=''
    HEALTH_URL='' ;;   # headless worker, no ALB / health URL
  *) echo "✖ Unknown service '$SERVICE'"; exit 1 ;;
esac

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
( cd "$REPO" && docker build --platform linux/amd64 -f "$DOCKERFILE" --target "$TARGET" -t "$IMAGE" "$CONTEXT" )

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
