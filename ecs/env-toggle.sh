#!/usr/bin/env bash
# env-toggle.sh — spin the whole test environment down to (near) zero cost when
# nobody's testing, and back up in ~90s when you are. No real users right now, so
# there's no reason to pay for idle Fargate tasks (public-IPv4 charge) or the
# bastion (public-IPv4 charge) between test sessions.
#
#   ./deploy/ecs/env-toggle.sh down     # scale every currently-running service to 0,
#                                        # stop the bastion. Saves the current desired
#                                        # counts so `up` restores exactly this set.
#   ./deploy/ecs/env-toggle.sh up       # restore desired counts from the last `down`,
#                                        # start the bastion, wait for services to
#                                        # reach steady state.
#   ./deploy/ecs/env-toggle.sh status   # show desired/running counts + bastion state.
#
# Deliberately does NOT touch: the ALB (no pause state — it bills hourly whether
# a task is behind it or not; tearing it down/rebuilding it is slow and risky, so
# it's treated as a fixed cost of being able to test at all), ECR, S3, CloudFront,
# RDS, Secrets Manager (all near-zero cost while idle).
#
# Only acts on services that are ALREADY desired>0 at the time `down` runs — a
# service someone has permanently scaled to 0 (e.g. mathesar, staging wrapper-web)
# is left alone and won't be turned on by `up`.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
STATE_FILE="$DIR/.env-toggle-state.json"
BASTION_TAG="zopkit-staging-bastion"
CLUSTERS=(zopkit-staging-ecs zopkit-prod-ecs)

cmd="${1:-status}"

bastion_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$BASTION_TAG" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null
}

bastion_state() {
  local id="$1"
  aws ec2 describe-instances --region "$REGION" --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null
}

status() {
  local cluster svc_arns
  for cluster in "${CLUSTERS[@]}"; do
    echo "── $cluster ──"
    svc_arns="$(aws ecs list-services --region "$REGION" --cluster "$cluster" --query 'serviceArns' --output text)"
    [ -z "$svc_arns" ] && { echo "  (no services)"; continue; }
    aws ecs describe-services --region "$REGION" --cluster "$cluster" --services $svc_arns \
      --query "services[].{Name:serviceName,Desired:desiredCount,Running:runningCount}" --output table
  done
  local bid
  bid="$(bastion_id)"
  if [ -n "$bid" ] && [ "$bid" != "None" ]; then
    echo "bastion ($bid): $(bastion_state "$bid")"
  else
    echo "bastion: not found"
  fi
}

down() {
  if [ -f "$STATE_FILE" ]; then
    echo "✗ $STATE_FILE already exists — looks like the env is already down (or a previous" >&2
    echo "  down didn't get matched with an up). Run '$0 up' first, or rm the state file" >&2
    echo "  if you're sure nothing needs restoring." >&2
    exit 1
  fi

  echo "→ snapshotting + scaling down running services …"
  local cluster svc_arns svc name desired entries=()
  for cluster in "${CLUSTERS[@]}"; do
    svc_arns="$(aws ecs list-services --region "$REGION" --cluster "$cluster" --query 'serviceArns' --output text)"
    [ -z "$svc_arns" ] && continue
    while IFS=$'\t' read -r name desired; do
      [ "$desired" = "0" ] && continue
      entries+=("{\"cluster\":\"$cluster\",\"service\":\"$name\",\"desired\":$desired}")
      echo "  ${cluster}/${name}: ${desired} → 0"
      aws ecs update-service --region "$REGION" --cluster "$cluster" --service "$name" \
        --desired-count 0 >/dev/null
    done < <(aws ecs describe-services --region "$REGION" --cluster "$cluster" --services $svc_arns \
      --query "services[].[serviceName,desiredCount]" --output text)
  done

  if [ "${#entries[@]}" -eq 0 ]; then
    echo "  (nothing was running)"
  fi
  printf '[%s]\n' "$(IFS=,; echo "${entries[*]}")" > "$STATE_FILE"

  local bid state
  bid="$(bastion_id)"
  if [ -n "$bid" ] && [ "$bid" != "None" ]; then
    state="$(bastion_state "$bid")"
    if [ "$state" = "running" ]; then
      echo "  bastion ($bid): stopping"
      aws ec2 stop-instances --region "$REGION" --instance-ids "$bid" >/dev/null
    else
      echo "  bastion ($bid): already $state"
    fi
  fi
  echo "✓ down. State saved to $STATE_FILE — restore with: $0 up"
}

up() {
  local bid state
  bid="$(bastion_id)"
  if [ -n "$bid" ] && [ "$bid" != "None" ]; then
    state="$(bastion_state "$bid")"
    if [ "$state" = "stopped" ]; then
      echo "  bastion ($bid): starting"
      aws ec2 start-instances --region "$REGION" --instance-ids "$bid" >/dev/null
    else
      echo "  bastion ($bid): already $state"
    fi
  fi

  if [ ! -f "$STATE_FILE" ]; then
    echo "  (no saved state — nothing to restore; env was already up, or 'down' was never run)"
    status
    return 0
  fi

  echo "→ restoring desired counts …"
  local cluster name desired
  # requires python3 (present on macOS by default) to parse the small JSON state file
  while IFS=$'\t' read -r cluster name desired; do
    echo "  ${cluster}/${name}: 0 → ${desired}"
    aws ecs update-service --region "$REGION" --cluster "$cluster" --service "$name" \
      --desired-count "$desired" >/dev/null
  done < <(python3 -c "
import json,sys
for e in json.load(open('$STATE_FILE')):
    print(f\"{e['cluster']}\t{e['service']}\t{e['desired']}\")
")
  rm -f "$STATE_FILE"

  echo "→ waiting for services to reach steady state (this can take ~1-2 min) …"
  for cluster in "${CLUSTERS[@]}"; do
    svc_arns="$(aws ecs list-services --region "$REGION" --cluster "$cluster" --query 'serviceArns' --output text)"
    [ -z "$svc_arns" ] && continue
    names=()
    for arn in $svc_arns; do
      n="$(basename "$arn")"
      d="$(aws ecs describe-services --region "$REGION" --cluster "$cluster" --services "$n" --query 'services[0].desiredCount' --output text)"
      [ "$d" != "0" ] && names+=("$n")
    done
    [ "${#names[@]}" -eq 0 ] && continue
    aws ecs wait services-stable --region "$REGION" --cluster "$cluster" --services "${names[@]}" \
      && echo "  ✓ $cluster: ${names[*]} stable" \
      || echo "  ✗ $cluster: ${names[*]} did not stabilize in time — check 'aws ecs describe-services'" >&2
  done
  echo "✓ up."
}

case "$cmd" in
  down)   down ;;
  up)     up ;;
  status) status ;;
  *) echo "usage: $0 [down|up|status]" >&2; exit 1 ;;
esac
