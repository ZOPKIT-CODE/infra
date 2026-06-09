# Accessing the staging RDS (Postgres)

The staging DB (`zopkit-staging-db`) is **private** — not on the public internet.
Three ways in, by use case:

## 1. Browse data in a UI → Mathesar (no setup)
Open **https://db.staging.zopkit.com**, log in with your Mathesar account.
Runs in-VPC, reaches the DB privately. Ask an admin for an account + the read-only
`wrapper_viewer` collaborator role. Nothing to install.

## 2. Direct psql / a desktop GUI → SSM tunnel
No SSH, no public exposure — Session Manager port-forwards `localhost:5432` to the
private RDS (IAM-gated, CloudTrail-audited).

One-time:
```bash
brew install --cask session-manager-plugin     # macOS (AWS CLI v2 also required)
```
Per session:
```bash
./deploy/ecs/db-tunnel.sh        # opens localhost:5432 -> RDS; leave running
# in another shell — grab the role you need:
aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id zopkit/staging/rds-wrapper-roles --query SecretString --output text
psql "postgresql://wrapper_viewer:<pw>@localhost:5432/wrapper_staging?sslmode=require"
```
Roles in that secret: `viewer` (read-only), `app` (DML), `migrator` (DDL/owner).

## 3. Query/analyze with Claude Code → Postgres MCP (auto-tunnel)
**No manual tunnel.** The MCP launcher (`mcp-db.sh`) opens the SSM tunnel on demand,
fetches the app's creds from Secrets Manager, and runs the Postgres MCP. Every app
tunnels on its **own stable local port** (from `db-apps.sh`), so several apps' MCPs
run side by side without colliding — that's what lets an admin keep all apps open
at once. The whole setup is **one command**:

```bash
# A developer — one app:
./deploy/ecs/setup-db-mcp.sh wrapper            # read-only MCP for one app
./deploy/ecs/setup-db-mcp.sh crm migrator       # full (write) access to one app

# An admin — every app at once (each on its own port, fully independent):
./deploy/ecs/setup-db-mcp.sh --all              # all apps, migrator
./deploy/ecs/setup-db-mcp.sh --all viewer       # all apps, read-only
```
Then restart Claude Code → approve the `postgres-<app>` server(s) → query. No
`db-tunnel.sh`, no localhost juggling; the launcher handles each tunnel itself.

**App fleet + ports** live in **`deploy/ecs/db-apps.sh`** (the single source of
truth): `wrapper→5432, crm→5433, fa→5434`. Add an app = one line there (next free
port) + the slug in `local.apps` (terraform) + provision its DB & secrets.

**Access level (2nd arg):**
- `viewer` (read-only) → analyze only. Default for a single dev (`setup-db-mcp.sh <app>`).
- `migrator` (full read/write/DDL) → the default for `--all` (admin), or pass it
  explicitly for one app. ⚠️ Powerful (modify/drop); staging is recoverable
  (backups + PITR). The role in the connection string is the real boundary.

## Onboarding (AWS SSO)
Browse-only? Use Mathesar (§1) — none of this needed. For **psql / a GUI / the
Claude-Code MCP**, attach the right customer-managed policy to the person's
**Identity Center permission set** (AWS console → IAM Identity Center → Permission
sets → … → Customer managed policy). Terraform: `iam-db-dev.tf`.

| Who | Policy to attach | Grants |
|---|---|---|
| **Developer (one app)** | `zopkit-staging-db-dev-<app>` (e.g. `-db-dev-wrapper`) | Full access to **that app's** DB only (its `-roles` + `-viewer` secrets) + SSM tunnel. |
| **Admin (all apps)** | `zopkit-staging-db-admin` | Full access to **every** app's DB + SSM tunnel. |

Then the dev/admin, one-time:
```bash
brew install --cask session-manager-plugin   # in their Terminal app (needs sudo)
aws sso login                                 # their Identity Center login
./deploy/ecs/setup-db-mcp.sh wrapper          # dev: their app   (or `--all` for admin)
```
Restart Claude Code → approve the `postgres-<app>` server(s). Done.

> **Isolation is by IAM, per app.** A dev with `db-dev-crm` can read only `crm`'s
> secrets, so even if they registered `postgres-fa` the MCP can't fetch `fa`'s
> creds. The admin policy is the only one that spans all apps.

## Notes
- This documents **staging**. Prod will be private (no admin IP allow-list);
  same tunnel/MCP pattern, different secret/host.
- Per-app isolation: each app has its own database (`<app>_staging`) + role
  secrets; access is scoped per app by IAM (see table above).
- Only `wrapper` is provisioned today. `crm`/`fa` are in the manifest but need
  their databases + `rds-<app>-{viewer,roles}` secrets created before their MCPs
  will connect.
