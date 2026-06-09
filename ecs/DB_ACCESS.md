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

## 3. Query/analyze with Claude Code → Postgres MCP
`.mcp.json` (local, gitignored) defines **`postgres-wrapper-staging`** — it fetches
DB creds from Secrets Manager at runtime and connects via the tunnel
(`localhost:5432`), so **no password is stored on disk**.

Use it:
1. Start the tunnel: `./deploy/ecs/db-tunnel.sh` (leave running).
2. Make sure AWS creds + the Session Manager plugin are set up.
3. (Re)start Claude Code and approve the `postgres-wrapper-staging` server.

**Access level — pick the role in the MCP command:**
- `viewer` (read-only) + `@modelcontextprotocol/server-postgres` → analyze only.
- `migrator` (full read/write/DDL) + `@henkey/postgres-mcp-server` → can also
  INSERT/UPDATE/DELETE + create/alter/drop. ⚠️ **Powerful** — the assistant can
  modify or delete data. Staging is recoverable (backups + PITR); for PROD prefer
  the read-only `viewer` role.

> The role in the connection string is the real boundary — the read-only
> `viewer` role can't write even if the MCP server allows it.

## Onboarding a dev for SQL/MCP access (AWS SSO)
Devs who only want to **browse** data need none of this — just Mathesar (§1). This
is for devs who want **psql / a GUI / the Claude-Code MCP** (read-only).

1. **Grant AWS access (admin, once per dev).** Attach the customer-managed policy
   **`zopkit-staging-db-dev-access`** to the dev's **Identity Center permission set**
   (AWS console → IAM Identity Center → Permission sets → … → Customer managed
   policy → `zopkit-staging-db-dev-access`). It grants ONLY: the read-only viewer
   secret + an SSM port-forward to the bastion. (Terraform: `iam-db-dev.tf`.)
2. **Dev installs + logs in:**
   ```bash
   brew install awscli session-manager-plugin
   aws sso login            # their Identity Center login
   ```
3. **Dev adds the read-only MCP to their Claude Code:**
   ```bash
   claude mcp add postgres-wrapper-staging -- bash -c \
   'u=$(aws secretsmanager get-secret-value --region us-east-1 \
   --secret-id zopkit/staging/rds-wrapper-viewer --query SecretString --output text \
   | python3 -c '"'"'import sys,json,re;u=json.load(sys.stdin)["viewer"];print(re.sub(r"@[^/@]+:5432","@localhost:5432",u))'"'"'); \
   exec npx -y @modelcontextprotocol/server-postgres "$u"'
   ```
   (This uses the **read-only viewer** secret + a read-only MCP server — the dev
   policy can't even read the write-capable `migrator` creds.)
4. **Per session:** `./deploy/ecs/db-tunnel.sh` (leave running) → restart Claude
   Code → approve the server. The dev now has read-only query access.

> Admins get full read/write by using `rds-wrapper-roles` (the `migrator` role) +
> a write-capable server (§3); devs are scoped to read-only by IAM (viewer secret).

## Notes
- This documents **staging**. Prod will be private (no admin IP allow-list);
  same tunnel/MCP pattern, different secret/host.
- Per-app isolation: each app gets its own database + `*_viewer` role; a viewer
  for one app can't reach another app's data.
