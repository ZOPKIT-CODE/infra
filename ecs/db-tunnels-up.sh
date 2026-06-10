#!/usr/bin/env bash
# db-tunnels-up.sh — open self-healing SSM tunnels for ALL app DBs at once, so the
# local backends (and psql / the DB-MCP) on your laptop can reach the PRIVATE
# staging RDS on each app's pinned local port (from db-apps.sh: wrapper 5432,
# crm 5433, fa 5434). The staging RDS is not public — these tunnels are the only
# way in from your machine.
#
#   ./deploy/ecs/db-tunnels-up.sh          # open every app's tunnel (background)
#   ./deploy/ecs/db-tunnels-up.sh status   # show which ports are up
#   ./deploy/ecs/db-tunnels-up.sh down     # stop the tunnels THIS script started
#
# Each tunnel runs under a supervisor that re-opens the SSM session if it drops
# (e.g. a broken pipe over a flaky/NAT64 network), so the local port stays alive.
# Tunnels persist after the command returns; stop them with `down`. Ports already
# up (e.g. opened by the postgres-* MCP servers) are left untouched.
#
# Prereqs: AWS CLI v2 + creds (aws sso login) and the Session Manager plugin.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=db-apps.sh
source "$DIR/db-apps.sh"

REGION="${AWS_REGION:-us-east-1}"
RUN_DIR="${TMPDIR:-/tmp}/zopkit-db-tunnels"
mkdir -p "$RUN_DIR"
cmd="${1:-up}"

# ── Internal: per-app self-healing supervisor (re-invoked via nohup; not for direct use).
if [ "$cmd" = "__supervise" ]; then
  app="${2:?}"; port="${3:?}"
  : "${BASTION:?}" "${RDS:?}"
  log="$RUN_DIR/$app.log"
  # On TERM, kill the aws child AND the session-manager-plugin it spawned (the
  # plugin is aws_pid's child and would otherwise orphan and keep the port bound).
  trap 'pkill -P "${aws_pid:-0}" 2>/dev/null; kill "${aws_pid:-0}" 2>/dev/null; exit 0' TERM INT
  while true; do
    aws ssm start-session --region "$REGION" --target "$BASTION" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"host\":[\"$RDS\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$port\"]}" \
      >>"$log" 2>&1 &
    aws_pid=$!
    wait "$aws_pid" || true
    echo "[db-tunnels] $port session exited; reopening in 2s …" >>"$log"
    sleep 2
  done
fi

status() {
  local app port
  for app in $(db_app_names); do
    port="$(db_app_port "$app")"
    if nc -z localhost "$port" 2>/dev/null; then
      echo "  ✓ ${app}  localhost:${port}  UP"
    else
      echo "  ✗ ${app}  localhost:${port}  down"
    fi
  done
}

down() {
  local app port pidf sup
  for app in $(db_app_names); do
    port="$(db_app_port "$app")"
    pidf="$RUN_DIR/${app}.pid"
    if [ -f "$pidf" ]; then
      sup="$(cat "$pidf")"
      kill -TERM "$sup" 2>/dev/null || true   # supervisor's trap stops its aws child + plugin
      pkill -P "$sup" 2>/dev/null || true
      # belt-and-suspenders: kill any session-manager-plugin still bound to OUR port
      # (only for apps we started — pidfile present — so MCP-owned tunnels are untouched).
      pkill -f "localPortNumber.*${port}" 2>/dev/null || true
      rm -f "$pidf"
      echo "  stopped ${app} (localhost:${port})"
    else
      echo "  ${app}: not started by this script (left as-is)"
    fi
  done
}

case "$cmd" in
  status) status; exit 0 ;;
  down)   down;   exit 0 ;;
  up)     : ;;
  *) echo "usage: $0 [up|down|status]" >&2; exit 1 ;;
esac

# ── up ────────────────────────────────────────────────────────────────────────
command -v session-manager-plugin >/dev/null 2>&1 || {
  echo "✗ session-manager-plugin not found. Install: brew install --cask session-manager-plugin" >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "✗ No AWS credentials. Run 'aws sso login' (or configure your profile), then re-run." >&2; exit 1; }

BASTION="$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Name,Values=zopkit-staging-bastion Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
RDS="$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier zopkit-staging-db --query 'DBInstances[0].Endpoint.Address' --output text)"
[ -n "$BASTION" ] && [ "$BASTION" != "None" ] || { echo "✗ No running bastion (tag zopkit-staging-bastion)." >&2; exit 1; }
[ -n "$RDS" ] && [ "$RDS" != "None" ] || { echo "✗ Could not resolve the RDS endpoint." >&2; exit 1; }

for app in $(db_app_names); do
  port="$(db_app_port "$app")"
  if nc -z localhost "$port" 2>/dev/null; then
    echo "  • ${app} already up (localhost:${port}) — leaving it"
    continue
  fi
  BASTION="$BASTION" RDS="$RDS" nohup bash "$0" __supervise "$app" "$port" >/dev/null 2>&1 &
  echo "$!" > "$RUN_DIR/${app}.pid"
  disown 2>/dev/null || true
done

echo "→ opening tunnels (self-healing) …"
for app in $(db_app_names); do
  port="$(db_app_port "$app")"
  for _ in $(seq 1 30); do nc -z localhost "$port" 2>/dev/null && break; sleep 1; done
done
status
echo "Tunnels are backgrounded + self-healing. Stop them with: $0 down"
