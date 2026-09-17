resource "aws_cloudwatch_log_group" "db_admin" {
  count             = var.enabled ? 1 : 0
  name              = "/ecs/${var.name_prefix}/db-admin"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_ecs_task_definition" "db_admin" {
  count                    = var.enabled ? 1 : 0
  family                   = "${var.name_prefix}-db-admin"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = var.execution_role_arn

  container_definitions = jsonencode([{
    name        = "db-admin"
    image       = "postgres:15-alpine"
    essential   = true
    command     = ["sh", "-lc", "printf '%s' \"$DB_ADMIN_SQL\" | psql \"$DB_ADMIN_URL\" -v ON_ERROR_STOP=1"]
    secrets     = [{ name = "DB_ADMIN_URL", valueFrom = "${var.rds_master_secret_arn}:url::" }]
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

  tags = var.tags
}
