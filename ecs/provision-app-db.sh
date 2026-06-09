#!/usr/bin/env bash
# provision-app-db.sh <app> — provision an app's database + per-app roles +
# Secrets Manager secrets on the SHARED staging RDS, mirroring the wrapper setup.
#
#   ./deploy/ecs/db-tunnel.sh &                 # open localhost:5432 -> RDS
#   ./deploy/ecs/provision-app-db.sh crm        # creates crm_staging + roles + secrets
#
# Creates: database <app>_<env>; roles <app>_{migrator,app,viewer}; secrets
# zopkit/<env>/rds-<app>-roles ({app,migrator,viewer}) and -viewer ({viewer}).
# Idempotent — re-running rotates the role passwords and re-syncs grants/secrets.
#
# After this, the DB-MCP for the app works: ./deploy/ecs/setup-db-mcp.sh <app>.
# Requires: an open SSM tunnel (localhost:5432), AWS creds that can read
# zopkit/<env>/rds-master and write Secrets Manager, and the backend workspace's
# node_modules (for the postgres.js client).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"

APP="${1:?usage: provision-app-db.sh <app>}"
REGION="${AWS_REGION:-us-east-1}"
ENV="${DB_ENV:-staging}"
DB="${APP}_${ENV}"
LPORT="${MCP_DB_PORT:-5432}"

if ! [[ "$APP" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "✗ Invalid app slug '$APP' (lowercase letters/digits/underscore)." >&2; exit 1
fi
if ! nc -z localhost "$LPORT" 2>/dev/null; then
  echo "✗ No tunnel on localhost:$LPORT — run ./deploy/ecs/db-tunnel.sh first." >&2; exit 1
fi
if [ ! -d "$REPO/backend/node_modules/postgres" ]; then
  echo "✗ backend/node_modules/postgres missing — run 'pnpm install' in backend/." >&2; exit 1
fi

# Master creds + RDS host (the secrets store the REAL host; apps/MCP rewrite to localhost).
MASTER=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "zopkit/${ENV}/rds-master" --query SecretString --output text)
HOST=$(echo "$MASTER" | python3 -c "import sys,json;print(json.load(sys.stdin)['host'])")
MASTER_URL=$(echo "$MASTER" | python3 -c "import sys,json,re;d=json.load(sys.stdin);print(re.sub(r'@[^/@]+:5432','@localhost:${LPORT}',d['url']))")

# Strong URL-safe (hex) passwords.
PW_MIG=$(openssl rand -hex 24); PW_APP=$(openssl rand -hex 24); PW_VIEW=$(openssl rand -hex 24)

echo "==> Provisioning ${DB} (roles: ${APP}_{migrator,app,viewer})"
PG_MODULE="$REPO/backend/node_modules/postgres" \
APP="$APP" DB="$DB" MASTER_URL="$MASTER_URL" \
PW_MIG="$PW_MIG" PW_APP="$PW_APP" PW_VIEW="$PW_VIEW" \
  node "$DIR/provision-app-db.cjs"

# Build the secret payloads (compact JSON, passwords passed via env — never argv/ps).
mk_json() {  # $1 = python dict expression using u(role,pw)
  APP="$APP" HOST="$HOST" DB="$DB" PW_MIG="$PW_MIG" PW_APP="$PW_APP" PW_VIEW="$PW_VIEW" \
  python3 - "$1" <<'PY'
import os,json,sys
a,h,db=os.environ['APP'],os.environ['HOST'],os.environ['DB']
def u(role,pw): return f"postgresql://{a}_{role}:{pw}@{h}:5432/{db}?sslmode=require"
pw={'migrator':os.environ['PW_MIG'],'app':os.environ['PW_APP'],'viewer':os.environ['PW_VIEW']}
print(json.dumps(eval(sys.argv[1]), separators=(',',':')))
PY
}
ROLES_JSON=$(mk_json "{'app':u('app',pw['app']),'migrator':u('migrator',pw['migrator']),'viewer':u('viewer',pw['viewer'])}")
VIEWER_JSON=$(mk_json "{'viewer':u('viewer',pw['viewer'])}")

put_secret() {  # name, json
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" --secret-string "$2" >/dev/null
    echo "  ✓ updated secret $1"
  else
    aws secretsmanager create-secret --region "$REGION" --name "$1" --secret-string "$2" \
      --description "Per-role Postgres URLs for the ${APP} ${ENV} DB" >/dev/null
    echo "  ✓ created secret $1"
  fi
}
put_secret "zopkit/${ENV}/rds-${APP}-roles" "$ROLES_JSON"
put_secret "zopkit/${ENV}/rds-${APP}-viewer" "$VIEWER_JSON"

echo "==> Done. ${DB} + roles + secrets ready. Register the MCP with: ./deploy/ecs/setup-db-mcp.sh ${APP}"
