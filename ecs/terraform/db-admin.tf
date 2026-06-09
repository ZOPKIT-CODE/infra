# db-admin.tf — a one-off, in-VPC psql task for provisioning per-app databases +
# roles on the RDS instance WITHOUT exposing it publicly. Run it with:
#
#   aws ecs run-task --cluster zopkit-staging-ecs --task-definition zopkit-staging-db-admin \
#     --launch-type FARGATE --network-configuration '<public-subnet + tasks SG + assignPublicIp>' \
#     --overrides '{"containerOverrides":[{"name":"db-admin","environment":[{"name":"DB_ADMIN_SQL","value":"CREATE DATABASE ...; CREATE ROLE ...;"}]}]}'
#
# DB_ADMIN_URL (the RDS master connection) is injected from Secrets Manager; the
# per-run SQL is passed as the DB_ADMIN_SQL env override. psql runs in autocommit
# so multi-statement scripts incl. CREATE DATABASE work.

resource "aws_cloudwatch_log_group" "db_admin" {
  count             = var.enable_rds ? 1 : 0
  name              = "/ecs/${local.name_prefix}/db-admin"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_ecs_task_definition" "db_admin" {
  count                    = var.enable_rds ? 1 : 0
  family                   = "${local.name_prefix}-db-admin"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([{
    name      = "db-admin"
    image     = "postgres:15-alpine"
    essential = true
    # SQL comes from the DB_ADMIN_SQL env override at run time; URL from the secret.
    command     = ["sh", "-lc", "printf '%s' \"$DB_ADMIN_SQL\" | psql \"$DB_ADMIN_URL\" -v ON_ERROR_STOP=1"]
    secrets     = [{ name = "DB_ADMIN_URL", valueFrom = "${aws_secretsmanager_secret.rds_master[0].arn}:url::" }]
    environment = [{ name = "DB_ADMIN_SQL", value = "SELECT 'override DB_ADMIN_SQL at run time';" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.db_admin[0].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "db-admin"
      }
    }
  }])

  tags = local.common_tags
}
