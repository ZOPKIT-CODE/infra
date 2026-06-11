# ---------------------------------------------------------------------------
# alb.tf — Shared internet-facing Application Load Balancer + its security
# group + HTTPS:443 / HTTP:80 listeners.
#
# There is ONE ALB for the whole suite. Each web service (wrapper-web,
# crm-web, fa-web) creates its own target group + host-header listener rule
# INSIDE modules/ecs-service (needs_alb = true). This file owns:
#   - the ALB security group (443/80 from the Internet)
#   - the load balancer itself (public subnets)
#   - the HTTPS:443 listener (ACM wildcard cert, default fixed-response 404)
#   - the HTTP:80 listener (301 -> HTTPS)
#   - the wrapper tenant-wildcard listener rule (*.<root> -> wrapper TG)
#
# The HTTPS listener ARN (aws_lb_listener.https.arn) is passed into each web
# service module as alb_listener_arn so it can attach its host-header rule.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ALB security group: 443 + 80 from anywhere, egress all (to reach task ENIs).
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Shared ALB - HTTPS/HTTP from the Internet, egress to ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere (redirected to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# ---------------------------------------------------------------------------
# The load balancer. Internet-facing, application type, in the public subnets.
# ---------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# ---------------------------------------------------------------------------
# HTTPS:443 listener. Terminates TLS with the primary-region wildcard ACM cert
# (local.acm_cert_arn). Default action is a 404 fixed response; host-header
# rules created by each web service module forward to that service's TG.
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.acm_cert_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  tags = {
    Name = "${local.name_prefix}-https"
  }
}

# ---------------------------------------------------------------------------
# HTTP:80 listener. 301-redirects every request to HTTPS:443.
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${local.name_prefix}-http-redirect"
  }
}

# ---------------------------------------------------------------------------
# Wrapper tenant-vanity wildcard rule. The wrapper service must serve both
# api.<root> (its own module-created rule at priority 10) AND *.<root> tenant
# hosts. Rather than widen the module's host_header condition, attach a
# dedicated catch-all rule here forwarding *.<root> to wrapper's
# target group. (`aws_route53_record.tenant_wildcard` aliases *.<root> -> ALB.)
#
# PRIORITY MUST SIT AFTER EVERY APP RULE (wrapper 10 / crm 20 / fa 30): at its
# old value (11) the wildcard swallowed crm-api.<root>/accounting-api.<root>
# before their host rules could match — every CRM API call was answered by
# WRAPPER (broken CORS, wrong app) while crm-web sat healthy and unreachable.
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "tenant_wildcard" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 90

  action {
    type             = "forward"
    target_group_arn = module.services["wrapper-web"].target_group_arn
  }

  condition {
    host_header {
      values = ["*.${var.root_domain}"]
    }
  }

  tags = {
    Name = "${local.name_prefix}-tenant-wildcard"
  }
}
