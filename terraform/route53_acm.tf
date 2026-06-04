# route53_acm.tf
# Route53 hosted zone (create or look up) + two DNS-validated ACM certificates:
#   - aws_acm_certificate.wildcard   : PRIMARY region (default provider) -> consumed by the ALB Ingress
#   - aws_acm_certificate.cloudfront : us-east-1 (provider aws.us_east_1) -> consumed by CloudFront
# Both cover the apex (var.root_domain) and the wildcard (*.var.root_domain).
#
# DNS records authored here are ONLY:
#   - ACM DNS-validation CNAMEs
#   - apex-frontend A-alias records (app/crm/accounting -> CloudFront)
# We deliberately DO NOT create api-* / ALB records or the *.zopkit.com tenant-wildcard
# record: those are managed dynamically by external-dns from the Kubernetes Ingress.

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
  # Default provider => var.aws_region. The ALB / load balancer controller
  # requires the cert to live in the same region as the load balancer.
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
}

# Validate the us-east-1 (CloudFront) certificate. Validation must run through
# the us_east_1 provider since the certificate lives there.
resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [
    for r in aws_route53_record.acm_validation : r.fqdn
  ]
}

############################################
# Frontend DNS — apex SPA hostnames -> CloudFront
############################################
# app.zopkit.com / crm.zopkit.com / accounting.zopkit.com alias to their
# CloudFront distributions (defined in cloudfront.tf). The hard-coded zone_id
# Z2FDTNDATAQYW2 is the global, well-known CloudFront alias hosted-zone ID.

resource "aws_route53_record" "frontend" {
  for_each = local.frontends

  zone_id = local.route53_zone_id
  name    = "${each.value.subdomain}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontends[each.key].domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# NOTE: api-* hostnames (wrapper/crm/fa APIs) and the *.zopkit.com tenant
# wildcard are intentionally NOT defined here — external-dns reconciles those
# from the shared ALB Ingress. Adding them statically would conflict.
