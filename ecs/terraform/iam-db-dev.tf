# iam-db-dev.tf — customer-managed policy granting a DEV the minimum to reach the
# staging RDS for read-only query/analysis (Mathesar needs none of this; this is
# only for the SSM tunnel + Postgres MCP / psql path). Attach it to an AWS
# Identity Center (SSO) permission set, or an IAM group/user.
#
# Grants ONLY: the read-only viewer connection secret (not migrator/app), an SSM
# port-forward session to the bastion, and the describe calls the tunnel helper
# needs. No direct DB network access (the RDS SG never allows arbitrary IPs).

resource "aws_iam_policy" "db_dev_access" {
  count       = var.enable_rds ? 1 : 0
  name        = "${local.name_prefix}-db-dev-access"
  description = "Dev read-only DB access: viewer creds + SSM tunnel to the bastion."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOnlyViewerSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:zopkit/${var.environment}/rds-wrapper-viewer-*"
      },
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
      }
    ]
  })
  tags = local.common_tags
}

output "db_dev_access_policy_arn" {
  description = "Attach this customer-managed policy to a dev Identity Center permission set (or IAM group)."
  value       = one(aws_iam_policy.db_dev_access[*].arn)
}
