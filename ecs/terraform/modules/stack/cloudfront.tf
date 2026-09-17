resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${local.name_prefix}-fe-oac"
  description                       = "OAC for Zopkit frontend S3 origins"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

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

resource "aws_cloudfront_distribution" "frontends" {
  for_each = local.frontends

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name_prefix} ${each.key} frontend (${each.value.subdomain}.${var.root_domain})"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  aliases = concat(
    ["${each.value.subdomain}.${var.root_domain}"],
    var.apex_frontend_app == each.key ? [var.root_domain] : [],
  )

  origin {
    domain_name              = aws_s3_bucket.buckets[each.value.bucket].bucket_regional_domain_name
    origin_id                = "s3-${each.value.bucket}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  dynamic "origin" {
    for_each = local.apps[each.key].cdn_proxies_api ? [1] : []
    content {
      domain_name = local.fqdn[each.key].api
      origin_id   = "alb-${each.key}"
      custom_origin_config {
        http_port                = 80
        https_port               = 443
        origin_protocol_policy   = "https-only"
        origin_ssl_protocols     = ["TLSv1.2"]
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

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
      origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-${each.value.bucket}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    dynamic "function_association" {
      for_each = local.apps[each.key].cdn_proxies_api ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.spa_routing[each.key].arn
      }
    }
  }

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
