#!/usr/bin/env bash
# setup-db-mcp.sh — one-time dev setup for the auto-tunneling DB MCP.
#
#   ./deploy/ecs/setup-db-mcp.sh wrapper          # read-only MCP for the wrapper DB
#   ./deploy/ecs/setup-db-mcp.sh crm              # ... or crm / fa
#
# Registers an MCP server that opens the SSM tunnel on demand (via mcp-db.sh), so
# the dev never runs the tunnel manually. After this, just restart Claude Code.
set -euo pipefail

APP="${1:-wrapper}"
ROLE="${2:-viewer}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Setting up the '$APP' DB MCP (role: $ROLE)"

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

# 3. Register the auto-tunneling MCP server with Claude Code.
if command -v claude >/dev/null 2>&1; then
  claude mcp add "postgres-${APP}" -- bash "$DIR/mcp-db.sh" "$APP" "$ROLE"
  echo "  ✓ registered MCP server 'postgres-${APP}'"
else
  cat >&2 <<EOF
  (claude CLI not found — add this to your .mcp.json manually:)
  "postgres-${APP}": { "command": "bash", "args": ["$DIR/mcp-db.sh", "$APP", "$ROLE"] }
EOF
fi

echo "==> Done. Restart Claude Code and approve 'postgres-${APP}'."
echo "    It opens the tunnel automatically on demand — no manual steps."
