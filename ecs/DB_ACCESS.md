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
**No manual tunnel.** The MCP launcher (`mcp-db.sh`) opens the SSM tunnel on demand
and closes it on exit, fetches the read-only creds from Secrets Manager, and runs
the Postgres MCP. So the whole dev setup is **one command**:

```bash
# one-time (after the plugin install + `aws sso login`):
./deploy/ecs/setup-db-mcp.sh wrapper      # registers the auto-tunneling MCP
# then restart Claude Code → approve 'postgres-wrapper' → query the DB
```
That's it — no `db-tunnel.sh`, no localhost juggling. The launcher handles the
tunnel each time Claude Code starts the server.

**Access level (2nd arg, default `viewer`):**
- `viewer` (read-only) → analyze only. **The default and the right choice for devs.**
- `migrator` (full read/write/DDL) → `./deploy/ecs/setup-db-mcp.sh wrapper migrator`.
  ⚠️ Powerful (modify/drop). Staging is recoverable (backups + PITR); for prod use `viewer`.

> The role in the connection string is the real boundary — the `viewer` role can't
> write even if the MCP server allows it. `mcp-db.sh` / `db-tunnel.sh` are the manual
> equivalents if you'd rather drive the tunnel yourself.

## Onboarding a dev for SQL/MCP access (AWS SSO)
Devs who only want to **browse** data need none of this — just Mathesar (§1). This
is for devs who want **psql / a GUI / the Claude-Code MCP** (read-only).

1. **Grant AWS access (admin, once per dev).** Attach the customer-managed policy
   **`zopkit-staging-db-dev-access`** to the dev's **Identity Center permission set**
   (AWS console → IAM Identity Center → Permission sets → … → Customer managed
   policy → `zopkit-staging-db-dev-access`). It grants ONLY: the read-only viewer
   secret + an SSM port-forward to the bastion. (Terraform: `iam-db-dev.tf`.)
2. **Dev installs the plugin + logs in (one-time):**
   ```bash
   brew install --cask session-manager-plugin   # in their Terminal app (needs sudo)
   aws sso login                                 # their Identity Center login
   ```
3. **Dev runs the one-command setup** (registers the auto-tunneling read-only MCP):
   ```bash
   ./deploy/ecs/setup-db-mcp.sh wrapper          # (or crm / fa)
   ```
4. **Restart Claude Code** → approve `postgres-wrapper`. Done — the MCP opens the
   tunnel on demand; no manual tunnel, no localhost juggling. Read-only by IAM
   (the dev policy can't even read the write-capable `migrator` creds).

> Admins get full read/write by using `rds-wrapper-roles` (the `migrator` role) +
> a write-capable server (§3); devs are scoped to read-only by IAM (viewer secret).

## Notes
- This documents **staging**. Prod will be private (no admin IP allow-list);
  same tunnel/MCP pattern, different secret/host.
- Per-app isolation: each app gets its own database + `*_viewer` role; a viewer
  for one app can't reach another app's data.
