# delegation.tf
# When root_domain is a SUBdomain we CREATE for this environment (e.g.
# staging.zopkit.com via create_route53_zone=true), the new zone only resolves
# publicly if its PARENT zone (zopkit.com) delegates to it. Without this NS
# delegation, ACM DNS-validation never completes and no *.staging.zopkit.com
# hostname resolves. Skipped automatically for an apex/pre-existing zone.

locals {
  domain_labels = split(".", var.root_domain)
  parent_domain = join(".", slice(local.domain_labels, 1, length(local.domain_labels)))
  # Delegate only when we created the zone AND root_domain is a subdomain (>2 labels).
  needs_delegation = var.create_route53_zone && length(local.domain_labels) > 2
}

data "aws_route53_zone" "parent" {
  count        = local.needs_delegation ? 1 : 0
  name         = local.parent_domain
  private_zone = false
}

resource "aws_route53_record" "zone_delegation" {
  count   = local.needs_delegation ? 1 : 0
  zone_id = data.aws_route53_zone.parent[0].zone_id
  name    = var.root_domain
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.this[0].name_servers
}
