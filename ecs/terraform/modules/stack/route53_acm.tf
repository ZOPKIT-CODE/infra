resource "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 1 : 0

  name    = var.root_domain
  comment = "${local.name_prefix} managed zone"

  tags = {
    Name = var.root_domain
  }
}

data "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 0 : 1

  name         = var.root_domain
  private_zone = false
}

resource "aws_acm_certificate" "wildcard" {
  domain_name               = var.root_domain
  subject_alternative_names = ["*.${var.root_domain}"]
  validation_method         = "DNS"

  tags = {
    Name = "${local.name_prefix}-wildcard"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name               = var.root_domain
  subject_alternative_names = ["*.${var.root_domain}"]
  validation_method         = "DNS"

  tags = {
    Name = "${local.name_prefix}-cloudfront"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id         = local.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [
    for r in aws_route53_record.acm_validation : r.fqdn
  ]
  depends_on = [aws_route53_record.zone_delegation]
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [
    for r in aws_route53_record.acm_validation : r.fqdn
  ]
  depends_on = [aws_route53_record.zone_delegation]
}

resource "aws_route53_record" "frontend" {
  for_each = var.manage_apex_dns ? local.live_frontends : {}

  zone_id         = local.route53_zone_id
  name            = "${each.value.subdomain}.${var.root_domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.frontends[each.key].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex_frontend" {
  count = var.manage_apex_dns && var.apex_frontend_app != "" ? 1 : 0

  zone_id         = local.route53_zone_id
  name            = var.root_domain
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.frontends[var.apex_frontend_app].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api" {
  for_each = var.manage_apex_dns ? local.live_apps : {}

  zone_id         = local.route53_zone_id
  name            = local.fqdn[each.key].api
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "tenant_wildcard" {
  count = var.manage_apex_dns ? 1 : 0

  zone_id         = local.route53_zone_id
  name            = "*.${var.root_domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
