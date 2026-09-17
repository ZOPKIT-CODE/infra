resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-ecs"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = "${local.name_prefix}-ecs"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}

resource "aws_security_group" "tasks" {
  name        = "${local.name_prefix}-ecs-tasks"
  description = "ECS Fargate task ENIs - ingress from ALB on container ports, egress all"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name_prefix}-ecs-tasks"
  }
}

resource "aws_security_group_rule" "tasks_from_alb" {
  for_each = toset([
    for name, svc in local.services :
    tostring(svc.container_port) if svc.container_port != null
  ])

  type                     = "ingress"
  description              = "From ALB on container port ${each.value}"
  from_port                = tonumber(each.value)
  to_port                  = tonumber(each.value)
  protocol                 = "tcp"
  security_group_id        = aws_security_group.tasks.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "tasks_egress_all" {
  type              = "egress"
  description       = "All egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.tasks.id
}
