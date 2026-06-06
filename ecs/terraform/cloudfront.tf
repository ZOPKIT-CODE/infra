# cloudfront.tf — CloudFront distributions for the three SPA frontends
# (wrapper=app, crm=crm, fa=accounting). Each fronts a PRIVATE S3 bucket via an
# Origin Access Control (OAC, SigV4) — the bucket stays locked down (s3.tf sets
# block-public-access + versioning + SSE) and only this distribution may read it.
#
# Frontend DNS A-alias records (app/crm/accounting -> these distributions) live in
# route53_acm.tf; API + *.zopkit.com records are managed by external-dns. This file
# owns the frontend bucket policies (s3.tf intentionally does NOT define them).

# ---------------------------------------------------------------------------
# Origin Access Control — shared by all three distributions. SigV4 signing,
# always sign, S3 origin type. Replaces the legacy OAI mechanism.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${local.name_prefix}-fe-oac"
  description                       = "OAC for Zopkit frontend S3 origins"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---------------------------------------------------------------------------
# One CloudFront distribution per frontend SPA. Backed by the matching private
# S3 bucket (local.frontends[*].bucket -> aws_s3_bucket.buckets[*]). SPA routing:
# 403/404 from S3 are rewritten to /index.html with a 200 so client-side routes
# (React Router etc.) resolve. TLS via the us-east-1 ACM cert (CloudFront only
# trusts certs in us-east-1).
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "frontends" {
  for_each = local.frontends

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name_prefix} ${each.key} frontend (${each.value.subdomain}.${var.root_domain})"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  # Custom domain served by this distribution.
  aliases = ["${each.value.subdomain}.${var.root_domain}"]

  # Private S3 bucket origin, reached through the OAC above.
  origin {
    domain_name              = aws_s3_bucket.buckets[each.value.bucket].bucket_regional_domain_name
    origin_id                = "s3-${each.value.bucket}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${each.value.bucket}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed "CachingOptimized" cache policy.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # SPA fallback: serve index.html (HTTP 200) for client-routed paths and for
  # access-denied responses S3/OAC returns on missing keys.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  viewer_certificate {
    # us-east-1 cert (route53_acm.tf, provider aws.us_east_1) — required by CloudFront.
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "${local.name_prefix}-fe-${each.key}"
  }
}

# ---------------------------------------------------------------------------
# Frontend bucket policies — grant CloudFront (this distribution only) read
# access to the bucket objects. Scoped by AWS:SourceArn so no other distribution
# or principal can read the private origin. s3.tf owns the public-access-block /
# versioning / encryption for these buckets; this file owns ONLY the policy.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "frontend_bucket" {
  for_each = local.frontends

  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.buckets[each.value.bucket].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontends[each.key].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  for_each = local.frontends

  bucket = aws_s3_bucket.buckets[each.value.bucket].id
  policy = data.aws_iam_policy_document.frontend_bucket[each.key].json
}
