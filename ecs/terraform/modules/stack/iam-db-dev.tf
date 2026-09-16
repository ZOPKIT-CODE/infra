# iam-db-dev.tf — customer-managed IAM policies for DB-MCP / psql access to the
# staging RDS via the SSM bastion. Attach to an Identity Center permission set,
# an IAM group, or a user. No policy grants direct DB network access — the RDS SG
# only allows the bastion + ECS tasks, so reaching the DB always goes through an
# SSM port-forward (IAM-gated, CloudTrail-audited).
#
# Two shapes, keyed off the existing app fleet (local.apps = wrapper|crm|fa, kept
# in sync with deploy/ecs/db-apps.sh):
#   * Per-app DEVELOPER policy  ("${name_prefix}-db-dev-<app>") — full (migrator)
#     access to exactly ONE app's database. Attach a dev only to their app.
#   * ADMIN policy              ("${name_prefix}-db-admin")      — full access to
#     ALL apps' databases at once (the 6-app simultaneous case).
#
# "Full access" = the app's `-roles` secret (which carries the migrator URL) plus
# the `-viewer` secret (so the same person can also open a read-only MCP).

# Statements every DB user needs regardless of which app(s): the SSM tunnel to the
# (only) bastion + the describe calls the tunnel helper makes. Reused below.
locals {
  db_tunnel_statements = [
    {
      Sid      = "DescribeForTunnelHelper"
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "rds:DescribeDBInstances"]
      Resource = "*"
    },
    {
      # Port-forward session ONLY to the tagged bastion (not arbitrary instances).
      Sid      = "StartSessionToBastion"
      Effect   = "Allow"
      Action   = "ssm:StartSession"
      Resource = "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"
      Condition = {
        StringEquals = { "ssm:resourceTag/Name" = "${local.name_prefix}-bastion" }
      }
    },
    {
      Sid      = "UsePortForwardDocument"
      Effect   = "Allow"
      Action   = "ssm:StartSession"
      Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSessionToRemoteHost"
    },
    {
      Sid      = "ManageSessions"
      Effect   = "Allow"
      Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
      Resource = "arn:aws:ssm:*:*:session/*"
    },
  ]

  # Both role secrets for one app: -roles (migrator) + -viewer (read-only).
  db_app_secret_arns = {
    for app in keys(local.apps) : app => [
      "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:zopkit/${var.environment}/rds-${app}-roles-*",
      "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:zopkit/${var.environment}/rds-${app}-viewer-*",
    ]
  }
}

# Per-app DEVELOPER policy: full access to exactly one app's DB.
resource "aws_iam_policy" "db_dev_app" {
  for_each    = var.enable_rds ? local.apps : {}
  name        = "${local.name_prefix}-db-dev-${each.key}"
  description = "Full (migrator) DB access to the ${each.key} staging DB via the SSM bastion."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "AppRoleSecrets"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.db_app_secret_arns[each.key]
      },
    ], local.db_tunnel_statements)
  })
  tags = local.common_tags
}

# ADMIN policy: full access to EVERY app's DB at once (the 6-simultaneous case).
resource "aws_iam_policy" "db_admin" {
  count       = var.enable_rds ? 1 : 0
  name        = "${local.name_prefix}-db-admin"
  description = "Full (migrator) DB access to ALL staging app DBs via the SSM bastion."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "AllAppRoleSecrets"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = flatten(values(local.db_app_secret_arns))
      },
    ], local.db_tunnel_statements)
  })
  tags = local.common_tags
}

output "db_dev_policy_arns" {
  description = "Per-app developer policy ARNs (attach a dev to their app only)."
  value       = { for app, p in aws_iam_policy.db_dev_app : app => p.arn }
}

output "db_admin_policy_arn" {
  description = "Admin policy ARN — full access to all app DBs (attach to the admin permission set/group)."
  value       = one(aws_iam_policy.db_admin[*].arn)
}
