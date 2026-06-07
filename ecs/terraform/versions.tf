# ---------------------------------------------------------------------------
# Provider + Terraform version constraints for the Zopkit suite ECS Fargate IaC.
#
# This is a self-contained ECS Fargate stack (no EKS / Kubernetes / Helm). The
# AWS-native services (Cognito, SNS/SQS, S3, CloudFront, ECR, Secrets Manager,
# SES inbound) are provisioned from files copied verbatim from the EKS stack;
# the compute layer is ECS Fargate + a shared ALB + task roles + native Secrets
# Manager injection + Terraform-managed Route53 records.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state (required for CI/CD — runners can't share a local state file).
  backend "s3" {
    bucket       = "zopkit-tfstate-207567767101"
    key          = "suite-ecs/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3-native state locking (Terraform >= 1.10); no DynamoDB
  }
}
