# route53_acm.tf
# Route53 hosted zone (create or look up) + two DNS-validated ACM certificates:
#   - aws_acm_certificate.wildcard   : PRIMARY region (default provider) -> consumed by the shared ALB
#   - aws_acm_certificate.cloudfront : us-east-1 (provider aws.us_east_1) -> consumed by CloudFront
# Both cover the apex (var.root_domain) and the wildcard (*.var.root_domain).
#
# DNS records authored here:
#   - ACM DNS-validation CNAMEs
#   - apex-frontend A-alias records (app/crm/accounting -> CloudFront)
#   - api-* A-alias records (api/crm-api/accounting-api -> shared ALB)
#   - *.zopkit.com tenant-wildcard A-alias record (-> shared ALB, served by wrapper)
#
# Unlike the EKS stack, there is NO external-dns: all API + tenant-wildcard records
# are managed statically here, aliasing the shared ALB (aws_lb.this in alb.tf).

############################################
# Hosted zone (create-or-reference)
############################################

# Create the zone when var.create_route53_zone = true ...
resource "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 1 : 0

  name    = var.root_domain
  comment = "${local.name_prefix} managed zone"

  tags = {
    Name = var.root_domain
  }
}

# ... otherwise look up the pre-existing zone (e.g. registrar-delegated).
data "aws_route53_zone" "this" {
  count = var.create_route53_zone ? 0 : 1

  name         = var.root_domain
  private_zone = false
}

# local.route53_zone_id (defined in locals.tf) resolves to whichever of the
# above is active; everything below references that local so it works either way.

############################################
# ACM certificate — PRIMARY region (ALB)
############################################

resource "aws_acm_certificate" "wildcard" {
  # Default provider => var.aws_region. The ALB requires the cert to live in the
  # same region as the load balancer.
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

############################################
# ACM certificate — us-east-1 (CloudFront)
############################################

resource "aws_acm_certificate" "cloudfront" {
  # CloudFront only accepts certificates issued in us-east-1.
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

############################################
# DNS validation records
############################################
# for_each MUST be keyed by a value known at plan time. domain_validation_options'
# resource_record_name is computed (unknown until apply) and cannot be a for_each
# key, but domain_name is static (var.root_domain + the wildcard SAN), so we key on
# that — the canonical ACM-DNS-validation pattern.
#
# Both certs (primary wildcard + us-east-1 cloudfront) request the IDENTICAL domain
# set, so ACM returns identical validation CNAMEs. We create ONE record set from the
# wildcard cert's options; the same records validate BOTH certs (referenced below).
# apex and *.apex share the same CNAME target, so allow_overwrite handles the dup.
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

# Validate the PRIMARY-region (ALB) certificate.
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [
    for r in aws_route53_record.acm_validation : r.fqdn
  ]
  # Wait for the parent-zone delegation (if any) so the validation CNAMEs in the
  # newly-created subdomain zone are publicly resolvable before ACM polls.
  depends_on = [aws_route53_record.zone_delegation]
}

# Validate the us-east-1 (CloudFront) certificate. Validation must run through
# the us_east_1 provider since the certificate lives there.
resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [
    for r in aws_route53_record.acm_validation : r.fqdn
  ]
  depends_on = [aws_route53_record.zone_delegation]
}

############################################
# Frontend DNS — apex SPA hostnames -> CloudFront
############################################
# app.zopkit.com / crm.zopkit.com / accounting.zopkit.com alias to their
# CloudFront distributions (defined in cloudfront.tf). The hard-coded zone_id
# Z2FDTNDATAQYW2 is the global, well-known CloudFront alias hosted-zone ID.

resource "aws_route53_record" "frontend" {
  # Gated by manage_apex_dns: empty map = no live records (build/validate first).
  # live_frontends filters to apps with a prod backend when dns_only_live_apps=true.
  for_each = var.manage_apex_dns ? local.live_frontends : {}

  zone_id = local.route53_zone_id
  name    = "${each.value.subdomain}.${var.root_domain}"
  type    = "A"
  # Overwrite any pre-existing record (e.g. a legacy box's A-record) on cutover.
  allow_overwrite = true

  alias {
    name                   = aws_cloudfront_distribution.frontends[each.key].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

############################################
# Apex frontend — root domain -> one app's CloudFront
############################################
# When apex_frontend_app is set (e.g. "wrapper"), the bare apex (zopkit.com) also
# aliases that app's CloudFront distribution, so the root domain serves the SPA in
# addition to <subdomain>.<root>. The cloudfront cert SANs cover the apex already.
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

############################################
# API DNS — backend hostnames -> shared ALB
############################################
# api.zopkit.com / crm-api.zopkit.com / accounting-api.zopkit.com alias the
# shared internet-facing ALB (aws_lb.this in alb.tf). There is no external-dns
# in this stack, so these records are managed statically here. The ALB's
# per-service host-header listener rules (created inside the ecs-service module)
# route each host to the correct target group.

resource "aws_route53_record" "api" {
  # Gated by manage_apex_dns (see frontend record above). live_apps filters to
  # apps with a prod backend when dns_only_live_apps=true.
  for_each = var.manage_apex_dns ? local.live_apps : {} # wrapper | crm | fa

  zone_id         = local.route53_zone_id
  name            = local.fqdn[each.key].api # api / crm-api / accounting-api .<root>
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

############################################
# Tenant vanity wildcard -> shared ALB (served by wrapper)
############################################
# *.<root_domain> tenant hostnames also alias the shared ALB. A dedicated
# listener rule (aws_lb_listener_rule.tenant_wildcard in alb.tf) matches the
# "*.${var.root_domain}" host header and forwards to the wrapper-web target
# group, so all tenant vanity subdomains reach wrapper.

resource "aws_route53_record" "tenant_wildcard" {
  # Gated by manage_apex_dns (see frontend record above). count, not for_each,
  # since this is a single record — staging state was migrated to [0] accordingly.
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
