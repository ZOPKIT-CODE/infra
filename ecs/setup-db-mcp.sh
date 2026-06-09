#!/usr/bin/env bash
# setup-db-mcp.sh — one-time setup for the auto-tunneling DB MCP(s).
#
# Per-app developer (one DB):
#   ./deploy/ecs/setup-db-mcp.sh wrapper            # read-only MCP for one app
#   ./deploy/ecs/setup-db-mcp.sh crm migrator       # full (write) access to one app
#
# Admin (all apps at once — each on its own port, fully independent):
#   ./deploy/ecs/setup-db-mcp.sh --all              # all apps, migrator
#   ./deploy/ecs/setup-db-mcp.sh --all viewer       # all apps, read-only
#
# Registers MCP server(s) that open the SSM tunnel on demand (via mcp-db.sh), so
# you never run a tunnel manually. After this, restart Claude Code and approve.
# The app fleet + per-app ports come from db-apps.sh (the single source of truth).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=db-apps.sh
source "$DIR/db-apps.sh"

# --- Parse args: either "--all [role]" (admin) or "<app> [role]" (one dev). -----
if [ "${1:-}" = "--all" ]; then
  ALL=1
  ROLE="${2:-migrator}"                  # admin defaults to full access
else
  ALL=0
  APP="${1:-wrapper}"
  ROLE="${2:-viewer}"                    # a single dev defaults to read-only
  if ! db_app_port "$APP" >/dev/null; then
    echo "✗ Unknown app '$APP'. Known apps: $(db_app_names | paste -sd' ' -)" >&2
    echo "  (Add it to deploy/ecs/db-apps.sh first.)" >&2
    exit 1
  fi
fi

# --- Shared prereq checks (do once, not per app). ------------------------------
# 1. Session Manager plugin (the one step that needs sudo — do it in a real terminal).
if ! command -v session-manager-plugin >/dev/null 2>&1; then
  cat >&2 <<EOF
✗ Session Manager plugin not found. Install it once (in your Terminal app):
    brew install --cask session-manager-plugin
  or:
    curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg" -o /tmp/sm.pkg
    sudo installer -pkg /tmp/sm.pkg -target /
Then re-run this script.
EOF
  exit 1
fi
echo "  ✓ session-manager-plugin"

# 2. AWS credentials.
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "✗ No AWS credentials. Run 'aws sso login' (or configure your profile), then re-run." >&2
  exit 1
fi
echo "  ✓ AWS credentials"

# --- Register one app's MCP server (idempotent: replace any prior registration).
register_app() {
  local app=$1 role=$2 port
  port="$(db_app_port "$app" || echo 5432)"
  echo "==> Registering '$app' DB MCP (role: $role, port: $port)"
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove "postgres-${app}" >/dev/null 2>&1 || true
    claude mcp add "postgres-${app}" -- bash "$DIR/mcp-db.sh" "$app" "$role"
    echo "  ✓ registered MCP server 'postgres-${app}'"
  else
    cat >&2 <<EOF
  (claude CLI not found — add this to your .mcp.json manually:)
  "postgres-${app}": { "command": "bash", "args": ["$DIR/mcp-db.sh", "$app", "$role"] }
EOF
  fi
}

if [ "$ALL" = "1" ]; then
  while IFS= read -r app; do register_app "$app" "$ROLE"; done < <(db_app_names)
  echo "==> Done. Restart Claude Code and approve: $(db_app_names | sed 's/^/postgres-/' | paste -sd' ' -)"
else
  register_app "$APP" "$ROLE"
  echo "==> Done. Restart Claude Code and approve 'postgres-${APP}'."
fi
echo "    Each opens its tunnel automatically on demand — no manual steps."
