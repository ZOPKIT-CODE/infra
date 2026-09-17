resource "aws_s3_bucket" "buckets" {
  for_each = local.s3_buckets

  bucket = each.value.name

  tags = {
    Name = each.value.name
  }
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ephemeral" {
  for_each = toset([
    for k in ["claim_check", "ses_inbound"] : k if contains(keys(local.s3_buckets), k)
  ])

  bucket = aws_s3_bucket.buckets[each.key].id

  depends_on = [aws_s3_bucket_versioning.buckets]

  rule {
    id     = "expire-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "crm_attachments" {
  bucket = aws_s3_bucket.buckets["crm_attachments"].id

  cors_rule {
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["https://${local.fqdn["crm"].frontend}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

resource "aws_s3_bucket_cors_configuration" "fa_receipts" {
  bucket = aws_s3_bucket.buckets["fa_receipts"].id

  cors_rule {
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["https://${local.fqdn["fa"].frontend}"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}
