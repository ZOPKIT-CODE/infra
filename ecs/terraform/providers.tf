# ---------------------------------------------------------------------------
# Providers.
#
# - aws            : primary region (everything: ECS Fargate, ALB, SNS/SQS,
#                    ElastiCache, Cognito, Secrets Manager). Default us-east-1.
# - aws.us_east_1  : pinned us-east-1 alias. CloudFront REQUIRES its ACM cert
#                    in us-east-1; keep this alias even if primary == us-east-1.
# - aws.crm_data   : region for CRM/FA S3 + SES (the apps read AWS_REGION for
#                    object storage today). Defaults to primary; override
#                    var.data_region to split.
#
# NOTE: there are intentionally NO kubernetes/helm providers — this stack runs
# the suite on ECS Fargate, not EKS.
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "crm_data"
  region = var.data_region
  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
