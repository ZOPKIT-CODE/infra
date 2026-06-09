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
`.mcp.json` defines **`postgres-wrapper-staging`** — it fetches the read-only
`wrapper_viewer` creds from Secrets Manager at runtime and connects via the tunnel
(`localhost:5432`), so **no password is stored in the repo**.

Use it:
1. Start the tunnel: `./deploy/ecs/db-tunnel.sh` (leave running).
2. Make sure AWS creds + the Session Manager plugin are set up.
3. (Re)start Claude Code and approve the `postgres-wrapper-staging` server.
   The MCP gives read-only `list`/`query` tools against `wrapper_staging`.

> The MCP + tunnel both use the read-only `wrapper_viewer` role, so AI/query
> access can read + analyze but never modify data.

## Notes
- This documents **staging**. Prod will be private (no admin IP allow-list);
  same tunnel/MCP pattern, different secret/host.
- Per-app isolation: each app gets its own database + `*_viewer` role; a viewer
  for one app can't reach another app's data.
