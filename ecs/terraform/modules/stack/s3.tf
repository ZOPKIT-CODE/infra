# s3.tf — Object storage buckets for the Zopkit suite.
#
# Buckets (from local.s3_buckets):
#   claim_check       — large SNS/SQS payload offload (claim-check pattern)
#   wrapper_logos     — wrapper tenant/org logo uploads
#   crm_attachments   — CRM record attachments (browser direct upload via CORS)
#   fa_receipts       — finance-accounting receipt uploads (browser direct upload via CORS)
#   ses_inbound       — raw inbound email objects written by the SES receipt rule
#   fe_wrapper        — wrapper SPA static assets (served via CloudFront)
#   fe_crm            — CRM SPA static assets (served via CloudFront)
#   fe_fa             — finance-accounting SPA static assets (served via CloudFront)
#
# All buckets are created under the DEFAULT provider (single region) to satisfy
# the pinned address aws_s3_bucket.buckets[<k>]. To split CRM/FA data storage into
# var.data_region, move crm_attachments/fa_receipts to provider = aws.crm_data
# (e.g. via a separate for_each over the data-region keys) and adjust outputs.tf.
#
# Conventions: block ALL public access, versioning Enabled, SSE AES256.
# Frontend bucket policies are intentionally NOT defined here — cloudfront.tf owns
# those (Origin Access Control grant).

############################################
# Buckets
############################################

resource "aws_s3_bucket" "buckets" {
  for_each = local.s3_buckets

  bucket = each.value.name

  tags = {
    Name = each.value.name
  }
}

############################################
# Block all public access (all four flags)
############################################

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################################
# Versioning (Enabled on every bucket)
############################################

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

############################################
# Server-side encryption (AES256)
############################################

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

############################################
# Lifecycle — expire current objects after 30 days for the
# ephemeral buckets (claim_check payloads + raw inbound email).
############################################

resource "aws_s3_bucket_lifecycle_configuration" "ephemeral" {
  for_each = toset([
    for k in ["claim_check", "ses_inbound"] : k if contains(keys(local.s3_buckets), k)
  ])

  bucket = aws_s3_bucket.buckets[each.key].id

  # Versioning is Enabled on all buckets, so configure noncurrent cleanup too
  # to avoid an unbounded history of expired objects.
  depends_on = [aws_s3_bucket_versioning.buckets]

  rule {
    id     = "expire-30-days"
    status = "Enabled"

    filter {} # apply to all objects in the bucket

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

############################################
# CORS — allow browser direct upload/download for the CRM and FA
# attachment buckets from their respective frontend origins.
############################################

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
