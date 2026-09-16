# Provider configuration for this environment.
#
# - aws           : primary region (ECS, ALB, SNS/SQS, Cognito, Secrets Manager)
# - aws.us_east_1 : pinned us-east-1. CloudFront REQUIRES its ACM cert there.
# - aws.crm_data  : region for CRM/FA S3 + SES; defaults to primary.
#
# default_tags must stay byte-identical to what the stack previously set, or
# every resource in state shows a tag diff.
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "zopkit-suite-ecs"
  }
}

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
