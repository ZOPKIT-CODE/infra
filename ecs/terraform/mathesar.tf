# mathesar.tf — Mathesar (web DB UI) as an in-VPC ECS service.
#
# Reaches the RDS instance over the PRIVATE network (tasks SG → rds SG), so the DB
# is never publicly exposed. Team accesses Mathesar at https://db.<root_domain>
# (behind the shared ALB; wildcard cert covers it). Its own metadata lives in a
# `mathesar_django` database on the RDS instance (created out-of-band via the
# db-admin task). Gated by var.enable_rds.

resource "random_password" "mathesar_db" {
  count   = var.enable_rds ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "mathesar_secret_key" {
  count   = var.enable_rds ? 1 : 0
  length  = 50
  special = false
}

resource "aws_secretsmanager_secret" "mathesar" {
  count = var.enable_rds ? 1 : 0
  name  = "zopkit/${var.environment}/mathesar"
  tags  = local.common_tags
}

resource "aws_secretsmanager_secret_version" "mathesar" {
  count     = var.enable_rds ? 1 : 0
  secret_id = aws_secretsmanager_secret.mathesar[0].id
  secret_string = jsonencode({
    POSTGRES_PASSWORD = random_password.mathesar_db[0].result
    SECRET_KEY        = random_password.mathesar_secret_key[0].result
  })
}

# Allow the ALB to reach Mathesar's container port (8000) — the app SG rules only
# cover local.services ports, so add Mathesar's explicitly.
resource "aws_security_group_rule" "tasks_from_alb_mathesar" {
  count                    = var.enable_rds ? 1 : 0
  type                     = "ingress"
  description              = "From ALB on Mathesar port 8000"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.tasks.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_cloudwatch_log_group" "mathesar" {
  count             = var.enable_rds ? 1 : 0
  name              = "/ecs/${local.name_prefix}/mathesar"
  retention_in_days = 14
  tags              = local.common_tags
}

resource "aws_ecs_task_definition" "mathesar" {
  count                    = var.enable_rds ? 1 : 0
  family                   = "${local.name_prefix}-mathesar"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([{
    name         = "mathesar"
    image        = "mathesar/mathesar:latest"
    essential    = true
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    environment = [
      { name = "POSTGRES_HOST", value = aws_db_instance.this[0].address },
      { name = "POSTGRES_PORT", value = "5432" },
      { name = "POSTGRES_DB", value = "mathesar_django" },
      { name = "POSTGRES_USER", value = "mathesar" },
      { name = "POSTGRES_SSLMODE", value = "require" },
      { name = "ALLOWED_HOSTS", value = "db.${var.root_domain}" },
    ]
    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.mathesar[0].arn}:POSTGRES_PASSWORD::" },
      { name = "SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.mathesar[0].arn}:SECRET_KEY::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mathesar[0].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "mathesar"
      }
    }
  }])

  tags = local.common_tags
}

resource "aws_lb_target_group" "mathesar" {
  count       = var.enable_rds ? 1 : 0
  name        = "${local.name_prefix}-mathesar"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    matcher             = "200,301,302"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  tags = local.common_tags
}

resource "aws_lb_listener_rule" "mathesar" {
  count        = var.enable_rds ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  # Must out-prioritize the tenant_wildcard rule (priority 11, matches
  # *.<root_domain> incl. db.<root_domain>) so db. routes to Mathesar, not wrapper.
  priority = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mathesar[0].arn
  }

  condition {
    host_header {
      values = ["db.${var.root_domain}"]
    }
  }
}

resource "aws_ecs_service" "mathesar" {
  count           = var.enable_rds ? 1 : 0
  name            = "${local.name_prefix}-mathesar"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.mathesar[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.fargate_assign_public_ip ? module.vpc.public_subnets : module.vpc.private_subnets
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = var.fargate_assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mathesar[0].arn
    container_name   = "mathesar"
    container_port   = 8000
  }

  # ALB rule must exist before the service registers targets.
  depends_on = [aws_lb_listener_rule.mathesar]

  tags = local.common_tags
}

# db.<root_domain> → shared ALB.
resource "aws_route53_record" "mathesar" {
  count   = var.enable_rds ? 1 : 0
  zone_id = local.route53_zone_id
  name    = "db.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

output "mathesar_url" {
  description = "Mathesar UI URL (in-VPC, behind the ALB)."
  value       = var.enable_rds ? "https://db.${var.root_domain}" : null
}
