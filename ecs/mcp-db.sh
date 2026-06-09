#!/usr/bin/env bash
# mcp-db.sh — self-contained Postgres MCP launcher for an app's staging DB.
#
# Devs add this ONCE as an MCP server and never touch the tunnel manually:
#   claude mcp add postgres-wrapper -- bash /abs/path/deploy/ecs/mcp-db.sh wrapper
#
# On each launch it: (1) ensures the SSM tunnel to the RDS is up (opens it if not,
# and tears it down on exit), (2) fetches the app's read-only viewer creds from
# Secrets Manager, (3) runs the Postgres MCP against localhost. No manual tunnel,
# no password on disk. Read-only by default; pass `migrator` as $2 for full access.
#
# Prereqs (one-time): AWS CLI v2 + creds (aws sso login), the Session Manager
# plugin, and `nc` (preinstalled on macOS/Linux).
set -euo pipefail

APP="${1:-wrapper}"
ROLE="${2:-viewer}"                      # viewer (read-only) | migrator (full)
REGION="${AWS_REGION:-us-east-1}"
PORT="${MCP_DB_PORT:-5432}"
SECRET="zopkit/staging/rds-${APP}-${ROLE}"
[ "$ROLE" = "migrator" ] && SECRET="zopkit/staging/rds-${APP}-roles"

log() { echo "[mcp-db] $*" >&2; }

# 1. Tunnel up? If not, open it (background) and close it when this process exits.
if ! nc -z localhost "$PORT" 2>/dev/null; then
  log "opening SSM tunnel localhost:$PORT -> RDS …"
  BASTION=$(aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:Name,Values=zopkit-staging-bastion Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  RDS=$(aws rds describe-db-instances --region "$REGION" \
    --db-instance-identifier zopkit-staging-db --query 'DBInstances[0].Endpoint.Address' --output text)
  aws ssm start-session --region "$REGION" --target "$BASTION" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$RDS\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$PORT\"]}" \
    >/tmp/mcp-db-tunnel-$APP.log 2>&1 &
  TUNNEL_PID=$!
  trap 'kill $TUNNEL_PID 2>/dev/null' EXIT
  for _ in $(seq 1 30); do nc -z localhost "$PORT" 2>/dev/null && break; sleep 1; done
  nc -z localhost "$PORT" 2>/dev/null || { log "tunnel failed — is the SSM plugin installed + aws creds valid?"; exit 1; }
  log "tunnel up"
fi

# 2. Fetch creds, rewrite host -> localhost (route through the tunnel).
URL=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" \
  --query SecretString --output text | python3 -c "
import sys,json,re
d=json.load(sys.stdin)
u=d.get('viewer') or d.get('migrator') or d.get('url')
print(re.sub(r'@[^/@]+:5432','@localhost:${PORT}',u))")

# 3. Run the MCP (read-only viewer -> read-only server; migrator -> write-capable).
if [ "$ROLE" = "migrator" ]; then
  exec npx -y @henkey/postgres-mcp-server --connection-string "$URL"
else
  exec npx -y @modelcontextprotocol/server-postgres "$URL"
fi
