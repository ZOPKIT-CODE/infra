#!/usr/bin/env bash
# db-tunnel.sh — open a psql shell against an app's staging DB.
#
# The staging RDS is publicly accessible (moved off the private-subnet+SSM-bastion
# setup), so there's no tunnel to open: this fetches the app's credentials from
# Secrets Manager and execs psql directly against the real RDS endpoint.
#
# Usage:
#   ./deploy/ecs/db-tunnel.sh                # wrapper, read-only (viewer)
#   ./deploy/ecs/db-tunnel.sh crm migrator   # crm, full (write) access
#
# Prereqs: AWS CLI v2 + creds (aws sso login), psql.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=db-apps.sh
source "$DIR/db-apps.sh"

REGION="${AWS_REGION:-us-east-1}"
APP="${1:-wrapper}"
ROLE="${2:-viewer}"                      # viewer (read-only) | migrator (full)

if ! db_app_port "$APP" >/dev/null; then
  echo "✗ Unknown app '$APP'. Known apps: $(db_app_names | paste -sd' ' -)" >&2
  echo "  (Add it to deploy/ecs/db-apps.sh first.)" >&2
  exit 1
fi

SECRET="zopkit/staging/rds-${APP}-${ROLE}"
[ "$ROLE" = "migrator" ] && SECRET="zopkit/staging/rds-${APP}-roles"

URL=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" \
  --query SecretString --output text | python3 -c "
import sys,json
d=json.load(sys.stdin)
# Pick the URL matching the requested role (the -roles secret holds BOTH viewer
# and migrator; don't blindly prefer viewer or migrator connections become read-only).
u=d.get('${ROLE}') or d.get('viewer') or d.get('migrator') or d.get('url')
print(u)")

echo "Connecting to '$APP' staging DB as '$ROLE' …" >&2
exec psql "$URL"
