# ---------------------------------------------------------------------------
# ecs.tf — Shared ECS Fargate cluster + capacity providers + the ECS task
# security group.
#
# Compute model: ECS Fargate behind the shared ALB (see alb.tf). All four
# suite services (wrapper-web, crm-web, fa-web, fa-consumer) run on this one
# cluster; the per-service task definitions / ECS services / target groups are
# instantiated via modules/ecs-service in services.tf.
#
# Networking: Fargate ENIs land in PUBLIC subnets with assign_public_ip = true
# by default (var.fargate_assign_public_ip), so no NAT gateway is required —
# the cheapest layout for staging. The task SG below admits traffic ONLY from
# the ALB SG (on the three container ports); fa-consumer has no port mapping
# and simply needs no ingress.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-ecs"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${local.name_prefix}-ecs"
  }
}

# Attach FARGATE (+ FARGATE_SPOT) capacity providers. Default strategy is plain
# FARGATE for predictable placement in staging; flip to FARGATE_SPOT per-service
# later if cost-optimising non-critical workers.
resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}

# ---------------------------------------------------------------------------
# ECS task security group. Shared by all four services' task ENIs.
#
#   ingress: each distinct web container port (3000 wrapper, 4000 crm,
#            3002 fa) FROM the ALB security group ONLY (no CIDR ingress).
#   egress : all (tasks reach SNS/SQS/S3/Cognito/Secrets/Valkey/Internet).
#
# fa-consumer shares this SG but maps no port, so the unused ingress rules are
# harmless for it. Valkey ingress (6379) is granted on the Valkey SG itself
# (see elasticache.tf), keyed off THIS security group.
# ---------------------------------------------------------------------------
resource "aws_security_group" "tasks" {
  name        = "${local.name_prefix}-ecs-tasks"
  description = "ECS Fargate task ENIs - ingress from ALB on container ports, egress all"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${local.name_prefix}-ecs-tasks"
  }
}

# One ingress rule per distinct web container port, sourced from the ALB SG.
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
