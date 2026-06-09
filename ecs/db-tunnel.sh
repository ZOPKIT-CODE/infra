#!/usr/bin/env bash
# db-tunnel.sh — open a secure localhost:5432 tunnel to the private staging RDS
# via the SSM bastion (no SSH, no public DB exposure, IAM-gated + CloudTrail-audited).
#
# Usage:
#   ./deploy/ecs/db-tunnel.sh                # forwards localhost:5432 -> RDS:5432
#   ./deploy/ecs/db-tunnel.sh 6543           # use a different local port
#
# Then point psql / a GUI / the Postgres MCP at localhost:<port>. The per-app
# credentials live in Secrets Manager (zopkit/staging/rds-wrapper-roles); fetch
# the role you need, e.g.:
#   aws secretsmanager get-secret-value --region us-east-1 \
#     --secret-id zopkit/staging/rds-wrapper-roles --query SecretString --output text
#
# Prereqs: AWS CLI v2 + the Session Manager plugin
#   macOS:  brew install --cask session-manager-plugin
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
LOCAL_PORT="${1:-5432}"
BASTION_TAG="zopkit-staging-bastion"
RDS_ID="zopkit-staging-db"

# Resolve the bastion instance id (by Name tag) + the RDS endpoint.
BASTION_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$BASTION_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
RDS_HOST=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].Endpoint.Address' --output text)

if [ -z "$BASTION_ID" ] || [ "$BASTION_ID" = "None" ]; then
  echo "No running bastion found (tag Name=$BASTION_TAG)." >&2; exit 1
fi

echo "Tunnel: localhost:$LOCAL_PORT  ->  $RDS_HOST:5432   (via bastion $BASTION_ID)"
echo "Leave this running; Ctrl-C to close."
exec aws ssm start-session --region "$REGION" --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}"
