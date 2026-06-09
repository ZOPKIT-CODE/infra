#!/usr/bin/env bash
# db-apps.sh — single source of truth for the DB-MCP app fleet.
#
# Every app has its own database (<app>_staging) + role secrets on the SHARED
# staging RDS instance, and a STABLE local port. The stable port lets several
# MCPs tunnel at once (e.g. an admin with all apps open) without colliding on
# 5432 — each app gets its own independent SSM tunnel on its own port.
#
# Add an app: append one "<app>:<port>" line with the next free port, then also
# add the slug to var.db_apps in terraform (iam-db-dev.tf) and provision its
# database + zopkit/staging/rds-<app>-{viewer,roles} secrets.
#
# Sourced by mcp-db.sh and setup-db-mcp.sh — defines no side effects, only data
# and helper functions.

DB_APPS=(
  "wrapper:5432"
  "crm:5433"
  "fa:5434"
  # "app4:5435"
  # "app5:5436"
  # "app6:5437"
)

# db_app_port <app> -> prints the app's stable local port, or returns 1 if unknown.
db_app_port() {
  local want=$1 entry
  for entry in "${DB_APPS[@]}"; do
    [ "${entry%%:*}" = "$want" ] && { echo "${entry##*:}"; return 0; }
  done
  return 1
}

# db_app_names -> prints every app slug, one per line.
db_app_names() {
  local entry
  for entry in "${DB_APPS[@]}"; do echo "${entry%%:*}"; done
}
