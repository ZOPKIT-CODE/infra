###############################################################################
# modules/ecs-service — resources
#
# Creates, for one ECS service:
#   * a Fargate/awsvpc task definition (single container)
#   * (web only) an ip-target-type target group + a host-header listener rule
#   * the ECS service (with optional load_balancer block)
#   * (autoscaled only) an appautoscaling target + CPU target-tracking policy
#
# The CloudWatch log group is owned by the root stack (observability.tf) and
# passed in via var.log_group_name; this module does NOT create it.
###############################################################################

# ---------------------------------------------------------------------------
# 1. Task definition
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = var.name
      image     = var.image
      essential = true
      command   = length(var.command) > 0 ? var.command : null

      portMappings = var.container_port == null ? [] : [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [for k, v in var.environment : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = var.name
        }
      }
    }
  ])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 2. Target group (web services only)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "this" {
  count = var.needs_alb ? 1 : 0

  name                 = substr("${var.name_prefix}-${var.name}", 0, 32)
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = var.container_port
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  dynamic "stickiness" {
    for_each = var.stickiness_enabled ? [1] : []
    content {
      type            = "lb_cookie"
      enabled         = true
      cookie_duration = 86400
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 3. Listener rule (web services only)
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "this" {
  count = var.needs_alb ? 1 : 0

  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }

  condition {
    host_header {
      values = concat([var.host_header], var.extra_host_headers)
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 4. ECS service
#
# ignore_changes = [desired_count] is set unconditionally: it is safe for
# pinned services (Terraform still sets the initial count on create) and
# required for autoscaled services (so the appautoscaling-driven count is not
# reverted on every apply).
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-${var.name}"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  launch_type     = "FARGATE"
  desired_count   = var.desired_count

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.task_security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  dynamic "load_balancer" {
    for_each = var.needs_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  health_check_grace_period_seconds = var.needs_alb ? 60 : null

  depends_on = [aws_lb_listener_rule.this]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 5. Autoscaling target (autoscaled services only)
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "this" {
  count = var.autoscaling_enabled ? 1 : 0

  max_capacity       = var.max_count
  min_capacity       = var.min_count
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# ---------------------------------------------------------------------------
# 6. Autoscaling policy — CPU target tracking (autoscaled services only)
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_policy" "cpu" {
  count = var.autoscaling_enabled ? 1 : 0

  name               = "${var.name_prefix}-${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target_value
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}
