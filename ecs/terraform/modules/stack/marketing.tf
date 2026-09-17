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

  origin {
    domain_name = local.fqdn["wrapper"].api
    origin_id   = "api-wrapper"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-fe_marketing"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern           = "/blog*"
    target_origin_id       = "s3-fe_marketing"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

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
      type        = "Service"
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
  publish          = true

  tags = {
    Name = "${local.name_prefix}-blog-bot-router"
  }
}
