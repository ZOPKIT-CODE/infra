#!/usr/bin/env bash
# mcp-db.sh — self-contained Postgres MCP launcher for an app's staging DB.
#
# Devs add this ONCE as an MCP server and never touch credentials manually:
#   claude mcp add postgres-wrapper -- bash /abs/path/deploy/ecs/mcp-db.sh wrapper
#
# The staging RDS is publicly accessible (moved off the private-subnet+SSM-bastion
# setup), so there's no tunnel to manage: this script just fetches the app's creds
# from Secrets Manager and runs the Postgres MCP directly against the RDS
# endpoint. No password on disk. Read-only by default; pass `migrator` as $2 for
# full access.
#
# Prereqs (one-time): AWS CLI v2 + creds (aws sso login).
set -euo pipefail

APP="${1:-wrapper}"
ROLE="${2:-viewer}"                      # viewer (read-only) | migrator (full)
REGION="${AWS_REGION:-us-east-1}"
SECRET="zopkit/staging/rds-${APP}-${ROLE}"
[ "$ROLE" = "migrator" ] && SECRET="zopkit/staging/rds-${APP}-roles"

log() { echo "[mcp-db] $*" >&2; }

# Fetch creds straight from Secrets Manager. Also force sslmode=no-verify: the
# RDS cert chains to Amazon's RDS CA, which isn't in Node's default trust store,
# so `pg` (used by both MCP servers below) fails with "self-signed certificate
# in certificate chain" under sslmode=require. Traffic is still TLS-encrypted;
# this only skips CA validation. (psql/libpq don't have this problem — sslmode=
# require already skips CA validation there — so db-tunnel.sh needs no such fix.)
URL=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" \
  --query SecretString --output text | python3 -c "
import sys,json,re
d=json.load(sys.stdin)
# Pick the URL matching the requested role (the -roles secret holds BOTH viewer
# and migrator; don't blindly prefer viewer or migrator MCPs become read-only).
u=d.get('${ROLE}') or d.get('viewer') or d.get('migrator') or d.get('url')
if 'sslmode=' in u:
    u=re.sub(r'sslmode=[^&]*','sslmode=no-verify',u)
else:
    u=u+('&' if '?' in u else '?')+'sslmode=no-verify'
print(u)")

# @henkey (migrator server) hardcodes a 2s connect timeout and closes idle
# connections after 30s, which can be tight for a cross-region TLS handshake
# over the public internet. Patch its cached build to wait longer and hold the
# pooled connection open. Idempotent + re-applied each launch, so it survives
# npx cache refreshes. (The viewer server uses pg's default no-timeout, so it
# needs no patch.)
patch_henkey_timeouts() {
  local f
  f=$(find "$HOME/.npm/_npx" -path "*@henkey/postgres-mcp-server/build/utils/connection.js" 2>/dev/null | head -1)
  if [ -z "$f" ]; then
    npx -y @henkey/postgres-mcp-server --version >/dev/null 2>&1 || true
    f=$(find "$HOME/.npm/_npx" -path "*@henkey/postgres-mcp-server/build/utils/connection.js" 2>/dev/null | head -1)
  fi
  [ -n "$f" ] || { log "could not locate @henkey to patch timeouts (continuing)"; return 0; }
  sed -i.bak -E \
    -e 's/connectionTimeoutMillis: options\.connectionTimeoutMillis \|\| 2000/connectionTimeoutMillis: options.connectionTimeoutMillis || 10000/' \
    -e 's/idleTimeoutMillis: options\.idleTimeoutMillis \|\| 30000/idleTimeoutMillis: options.idleTimeoutMillis || 0/' \
    "$f" 2>/dev/null || true
}

# Run the MCP (read-only viewer -> read-only server; migrator -> write-capable).
if [ "$ROLE" = "migrator" ]; then
  patch_henkey_timeouts
  npx -y @henkey/postgres-mcp-server --connection-string "$URL"
else
  npx -y @modelcontextprotocol/server-postgres "$URL"
fi
