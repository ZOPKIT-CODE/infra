#!/usr/bin/env bash
# mcp-db.sh — self-contained Postgres MCP launcher for an app's staging DB.
#
# Devs add this ONCE as an MCP server and never touch the tunnel manually:
#   claude mcp add postgres-wrapper -- bash /abs/path/deploy/ecs/mcp-db.sh wrapper
#
# On each launch it: (1) ensures the SSM tunnel to the RDS is up (opens it if not,
# and tears it down on exit), (2) fetches the app's creds from Secrets Manager,
# (3) runs the Postgres MCP against localhost. No manual tunnel, no password on
# disk. Read-only by default; pass `migrator` as $2 for full access.
#
# Each app tunnels on its OWN stable local port (from db-apps.sh), so multiple
# apps' MCPs (e.g. an admin with all 6 open) run side by side without colliding.
#
# Prereqs (one-time): AWS CLI v2 + creds (aws sso login), the Session Manager
# plugin, and `nc` (preinstalled on macOS/Linux).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=db-apps.sh
source "$DIR/db-apps.sh"

APP="${1:-wrapper}"
ROLE="${2:-viewer}"                      # viewer (read-only) | migrator (full)
REGION="${AWS_REGION:-us-east-1}"
# Per-app stable port from the manifest; MCP_DB_PORT overrides; 5432 if unknown.
PORT="${MCP_DB_PORT:-$(db_app_port "$APP" || echo 5432)}"
SECRET="zopkit/staging/rds-${APP}-${ROLE}"
[ "$ROLE" = "migrator" ] && SECRET="zopkit/staging/rds-${APP}-roles"

log() { echo "[mcp-db] $*" >&2; }

# Tear down only the tunnel WE started (SUP_PID set): stop the supervisor, its
# current aws child, and the session-manager-plugin bound to OUR local port
# (matched precisely via localPortNumber so we never kill another app's tunnel).
cleanup_tunnel() {
  [ -n "${SUP_PID:-}" ] || return 0
  kill -TERM "$SUP_PID" 2>/dev/null || true
  pkill -P "$SUP_PID" 2>/dev/null || true
  pkill -f "localPortNumber\":\[\"$PORT\"" 2>/dev/null || true
}

# 1. Tunnel up? If not, open a SELF-HEALING tunnel and tear it down on exit.
#    The SSM session can drop (e.g. a broken pipe over a flaky/NAT64 network); a
#    plain one-shot tunnel would then leave the MCP unusable until restart. So we
#    run a supervisor that re-opens the session whenever it exits, for the life of
#    this process. node-postgres just reconnects on the next query.
if ! nc -z localhost "$PORT" 2>/dev/null; then
  log "opening self-healing SSM tunnel localhost:$PORT -> RDS …"
  BASTION=$(aws ec2 describe-instances --region "$REGION" \
    --filters Name=tag:Name,Values=zopkit-staging-bastion Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  RDS=$(aws rds describe-db-instances --region "$REGION" \
    --db-instance-identifier zopkit-staging-db --query 'DBInstances[0].Endpoint.Address' --output text)
  (
    # Supervisor subshell: keep one SSM session alive; restart it if it exits.
    trap 'kill "${aws_pid:-0}" 2>/dev/null; exit 0' TERM INT
    while true; do
      aws ssm start-session --region "$REGION" --target "$BASTION" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{\"host\":[\"$RDS\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$PORT\"]}" \
        >>"/tmp/mcp-db-tunnel-$APP.log" 2>&1 &
      aws_pid=$!
      wait "$aws_pid"
      echo "[mcp-db] tunnel session exited; reopening in 2s …" >>"/tmp/mcp-db-tunnel-$APP.log"
      sleep 2
    done
  ) &
  SUP_PID=$!
  # On exit/termination, stop the supervisor + its SSM child + our plugin.
  trap cleanup_tunnel EXIT INT TERM
  for _ in $(seq 1 30); do nc -z localhost "$PORT" 2>/dev/null && break; sleep 1; done
  nc -z localhost "$PORT" 2>/dev/null || { log "tunnel failed — is the SSM plugin installed + aws creds valid?"; exit 1; }
  log "tunnel up (self-healing)"
fi

# 2. Fetch creds, rewrite host -> localhost (route through the tunnel).
#    Also force sslmode=no-verify: we connect to localhost, so the RDS cert's
#    hostname/CA can never validate, and node-postgres treats sslmode=require as
#    verify-CA (-> "self-signed certificate in certificate chain"). Traffic is
#    already encrypted by the SSM tunnel, so skipping cert verification is safe.
URL=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" \
  --query SecretString --output text | python3 -c "
import sys,json,re
d=json.load(sys.stdin)
# Pick the URL matching the requested role (the -roles secret holds BOTH viewer
# and migrator; don't blindly prefer viewer or migrator MCPs become read-only).
u=d.get('${ROLE}') or d.get('viewer') or d.get('migrator') or d.get('url')
u=re.sub(r'@[^/@]+:5432','@localhost:${PORT}',u)
if 'sslmode=' in u:
    u=re.sub(r'sslmode=[^&]*','sslmode=no-verify',u)
else:
    u=u+('&' if '?' in u else '?')+'sslmode=no-verify'
print(u)")

# 3. Run the MCP (read-only viewer -> read-only server; migrator -> write-capable).
#    NOT exec'd: we keep the bash process so the cleanup_tunnel EXIT trap fires and
#    the self-healing tunnel is torn down with the server (exec would orphan it).
if [ "$ROLE" = "migrator" ]; then
  npx -y @henkey/postgres-mcp-server --connection-string "$URL"
else
  npx -y @modelcontextprotocol/server-postgres "$URL"
fi
