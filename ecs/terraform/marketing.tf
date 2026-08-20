# marketing.tf — the frontend-marketing (www.zopkit.com / zopkit.com) CloudFront
# distribution. Created out-of-band during the marketing-site split
# (2026-07-25, no ManagedBy tag) and imported here so it can be safely extended
# with UA-based bot routing for blog link-preview unfurling (see the Lambda@Edge
# association below). Reuses the SAME shared OAC + ACM cert as the frontends
# in cloudfront.tf (confirmed live: OAC E14K2TOMA3ALDG = aws_cloudfront_origin_access_control.this,
# cert 821c5f70-... = aws_acm_certificate_validation.cloudfront) — this was
# built by hand to match the existing pattern, not created independently of it.
resource "aws_cloudfront_distribution" "marketing" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${local.name_prefix} marketing frontend (www.${var.root_domain})"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2"

  aliases = ["www.${var.root_domain}", var.root_domain]

  origin {
    domain_name              = "${local.name_prefix}-marketing-fe.s3.${var.aws_region}.amazonaws.com"
    origin_id                = "s3-fe_marketing"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  # Wrapper's API. Declared for visibility only - no cache behavior targets
  # this origin_id directly. The blog-bot-router Lambda@Edge (below) builds
  # its own inline custom-origin object at request time when it overrides a
  # bot request's origin (CloudFront's Lambda@Edge origin override does not
  # require the target to be a pre-declared origin), so this block is not
  # strictly load-bearing - it documents intent and leaves room for a future
  # non-Lambda behavior to target "api-wrapper" directly if ever needed.
  origin {
    domain_name = local.fqdn["wrapper"].api
    origin_id   = "api-wrapper"

    custom_origin_config {
      http_port                = 80
      https_port                = 443
      origin_protocol_policy    = "https-only"
      origin_ssl_protocols      = ["TLSv1.2"]
      origin_read_timeout       = 30
      origin_keepalive_timeout  = 5
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-fe_marketing"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed "CachingOptimized" cache policy (matches cloudfront.tf's frontends).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Blog link-preview unfurling: bots (LinkedIn/WhatsApp/Slack/etc., see
  # lambda/blog-bot-router) get routed to the wrapper backend's server-rendered
  # og:title/og:image HTML instead of the SPA shell; humans are unaffected
  # (default target stays S3, same as default_cache_behavior).
  #
  # cache_policy_id is CachingDisabled (not CachingOptimized) DELIBERATELY:
  # CloudFront's cache key does not include User-Agent by default, so if this
  # path were cacheable, a bot's request could populate the shared edge cache
  # for /blog/<slug>, and a subsequent HUMAN request for the exact same URL
  # from the same edge location could be served the cached BOT response (the
  # static prerendered HTML) instead of the real SPA. Disabling caching means
  # the Lambda re-evaluates the UA fresh on every single request - no shared
  # cache key, no pollution risk. The backend already sets its own
  # Cache-Control for whoever ends up fetching from it directly.
  ordered_cache_behavior {
    path_pattern           = "/blog*"
    target_origin_id       = "s3-fe_marketing"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed "CachingDisabled".
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # AWS managed "UserAgentRefererHeaders" - REQUIRED for the Lambda to see the
    # real viewer User-Agent. CloudFront replaces User-Agent with the generic
    # string "Amazon CloudFront" before origin-request fires unless a policy
    # explicitly forwards it (learned the hard way testing this live - every
    # request looked identical to the bot check without this). NOT
    # AllViewerExceptHostHeader (the lens app's choice, and my first attempt
    # here) - CloudFront rejects that for an S3 target origin: "Origin S3 Origins
    # can only use the following managed request policies: CORS-CustomOrigin,
    # CORS-S3Origin, UserAgentRefererHeaders." This behavior's default target
    # IS the S3 origin (s3-fe_marketing), so the policy must be one of those
    # three; this one is the only one that forwards User-Agent.
    origin_request_policy_id = "acba4595-bd28-49b8-b9fe-13317c0390fa"

    lambda_function_association {
      event_type   = "origin-request"
      lambda_arn   = aws_lambda_function.blog_bot_router.qualified_arn
      include_body = false
    }
  }

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
    Name = "${local.name_prefix}-fe-marketing"
  }
}

# ---------------------------------------------------------------------------
# Lambda@Edge: origin-request bot router for /blog* (lambda/blog-bot-router).
# Must be created in us-east-1 (provider aws.us_east_1 - same alias already
# used for the CloudFront ACM cert in route53_acm.tf) and referenced by a
# PUBLISHED, QUALIFIED version ARN - CloudFront rejects $LATEST/aliases here.
# ---------------------------------------------------------------------------
data "archive_file" "blog_bot_router" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/blog-bot-router"
  output_path = "${path.module}/lambda/blog-bot-router.zip"
}

data "aws_iam_policy_document" "lambda_edge_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      # Lambda@Edge requires BOTH principals to trust the role.
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "blog_bot_router" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-blog-bot-router"
  assume_role_policy = data.aws_iam_policy_document.lambda_edge_assume.json

  tags = {
    Name = "${local.name_prefix}-blog-bot-router"
  }
}

# CloudWatch Logs only - this function makes no AWS API calls, just inspects/
# rewrites the request object.
resource "aws_iam_role_policy_attachment" "blog_bot_router_logs" {
  provider   = aws.us_east_1
  role       = aws_iam_role.blog_bot_router.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "blog_bot_router" {
  provider         = aws.us_east_1
  function_name    = "${local.name_prefix}-blog-bot-router"
  role             = aws_iam_role.blog_bot_router.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  filename         = data.archive_file.blog_bot_router.output_path
  source_code_hash = data.archive_file.blog_bot_router.output_base64sha256
  publish          = true # Lambda@Edge requires a published version, not $LATEST.

  tags = {
    Name = "${local.name_prefix}-blog-bot-router"
  }
}
