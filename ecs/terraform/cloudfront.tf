# cloudfront.tf — CloudFront distributions for the three SPA frontends
# (wrapper=app, crm=crm, fa=accounting). Each fronts a PRIVATE S3 bucket via an
# Origin Access Control (OAC, SigV4) — the bucket stays locked down (s3.tf sets
# block-public-access + versioning + SSE) and only this distribution may read it.
#
# Frontend DNS A-alias records (app/crm/accounting -> these distributions) live in
# route53_acm.tf; API + *.zopkit.com records are managed by external-dns. This file
# owns the frontend bucket policies (s3.tf intentionally does NOT define them).

# Origin Access Control — shared by all three distributions. SigV4 signing,
# always sign, S3 origin type. Replaces the legacy OAI mechanism.
resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${local.name_prefix}-fe-oac"
  description                       = "OAC for Zopkit frontend S3 origins"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# SPA routing via edge function instead of custom_error_response, for apps that
# also proxy /api/* through this same distribution (cdn_proxies_api = true).
# custom_error_response (403/404 -> index.html) applies DISTRIBUTION-WIDE, not
# per-behavior - it was rewriting the backend's legitimate JSON 404s (e.g. "no
# site for this host") into the SPA HTML shell. Rewriting non-file request URIs
# to /index.html (or /gallery.html for /g/<token>) at viewer-request time, on
# the S3 default behavior only, means S3 never 404s for a real client route in
# the first place - so custom_error_response can be dropped for these apps
# entirely and the /api/* behavior's real error responses pass through untouched.
resource "aws_cloudfront_function" "spa_routing" {
  for_each = { for k, v in local.apps : k => v if v.cdn_proxies_api }

  name    = "${local.name_prefix}-${each.key}-spa-routing"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite non-file paths to /index.html (or /gallery.html for /g/<token>) for ${each.key}"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      var segments = request.uri.split('/').filter(function (s) { return s.length > 0; });
      var lastSegment = segments.length > 0 ? segments[segments.length - 1] : '';

      if (lastSegment.indexOf('.') !== -1) {
        return request; // real static file (e.g. /assets/main-xyz.js, /favicon.ico)
      }

      if (segments.length === 2 && segments[0] === 'g') {
        request.uri = '/gallery.html';
        return request;
      }

      request.uri = '/index.html';
      return request;
    }
  JS
}

# One CloudFront distribution per frontend SPA. Backed by the matching private
# S3 bucket (local.frontends[*].bucket -> aws_s3_bucket.buckets[*]). SPA routing:
# 403/404 from S3 are rewritten to /index.html with a 200 so client-side routes
# (React Router etc.) resolve. TLS via the us-east-1 ACM cert (CloudFront only
# trusts certs in us-east-1).
resource "aws_cloudfront_distribution" "frontends" {
  for_each = local.frontends

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name_prefix} ${each.key} frontend (${each.value.subdomain}.${var.root_domain})"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  # Custom domain served by this distribution. The app named in apex_frontend_app
  # also serves the bare apex (root_domain) — the cloudfront cert SANs cover it.
  aliases = concat(
    ["${each.value.subdomain}.${var.root_domain}"],
    var.apex_frontend_app == each.key ? [var.root_domain] : [],
  )

  # Private S3 bucket origin, reached through the OAC above.
  origin {
    domain_name              = aws_s3_bucket.buckets[each.value.bucket].bucket_regional_domain_name
    origin_id                = "s3-${each.value.bucket}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  # Backend ALB origin - only for apps whose frontend has no configurable API base URL and
  # must reach /api/* same-origin (see local.apps[*].cdn_proxies_api). domain_name is the
  # app's OWN api subdomain (not the raw ALB DNS name) so CloudFront's default custom-origin
  # Host header matches the ALB listener rule's host_header condition for this app.
  dynamic "origin" {
    for_each = local.apps[each.key].cdn_proxies_api ? [1] : []
    content {
      domain_name = local.fqdn[each.key].api
      origin_id   = "alb-${each.key}"
      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
        # Default (30s) is shorter than the ALB's own idle_timeout (60s), so CloudFront was
        # returning 504 before the ALB/backend even timed out - on cross-region DB queries
        # (Supabase in ap-northeast-1) that run close to the ALB's timeout. Match the ALB's 60s
        # (the max settable without an AWS support request).
        origin_read_timeout      = 60
        origin_keepalive_timeout = 5
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.apps[each.key].cdn_proxies_api ? [1] : []
    content {
      path_pattern           = "/api/*"
      target_origin_id       = "alb-${each.key}"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      # AWS managed "CachingDisabled" - API responses are dynamic, never cache.
      cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      # AWS managed "AllViewerExceptHostHeader" - forward all headers/cookies/query strings
      # (auth, CORS) EXCEPT Host: the viewer's Host is "lens.<root_domain>" (the frontend), which
      # doesn't match this app's ALB listener rule (host_header = "lens-api.<root_domain>") and
      # was falling through to wrapper's tenant-wildcard catch-all instead. Excluding Host lets
      # CloudFront send the origin's own domain_name as Host, matching the right listener rule.
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-${each.value.bucket}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed "CachingOptimized" cache policy.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    dynamic "function_association" {
      for_each = local.apps[each.key].cdn_proxies_api ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.spa_routing[each.key].arn
      }
    }
  }

  # SPA fallback: serve index.html (HTTP 200) for client-routed paths and for
  # access-denied responses S3/OAC returns on missing keys. Apps that proxy /api/*
  # through this distribution use the spa_routing function above instead (see its
  # comment) - custom_error_response would also rewrite the API's real 404s.
  dynamic "custom_error_response" {
    for_each = local.apps[each.key].cdn_proxies_api ? [] : [1]
    content {
      error_code            = 403
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
  }

  dynamic "custom_error_response" {
    for_each = local.apps[each.key].cdn_proxies_api ? [] : [1]
    content {
      error_code            = 404
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
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

# Frontend bucket policies — grant CloudFront (this distribution only) read
# access to the bucket objects. Scoped by AWS:SourceArn so no other distribution
# or principal can read the private origin. s3.tf owns the public-access-block /
# versioning / encryption for these buckets; this file owns ONLY the policy.
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
