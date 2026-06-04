# ---------------------------------------------------------------------------
# Providers.
#
# - aws            : primary region (everything: EKS, SNS/SQS, EventBridge,
#                    ElastiCache, Cognito, ALB). Default us-east-1.
# - aws.us_east_1  : pinned us-east-1 alias. CloudFront REQUIRES its ACM cert
#                    in us-east-1; keep this alias even if primary == us-east-1.
# - aws.crm_data   : region for CRM/FA S3 + SES (the apps read AWS_REGION=
#                    ap-south-1 for object storage today). Defaults to primary;
#                    override var.data_region to split.
# - kubernetes/helm: authenticated against the EKS cluster created in this stack
#                    via a short-lived token (aws eks get-token).
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

# kubernetes / helm providers are wired from the EKS module outputs. On the very
# first apply the cluster does not exist yet; bootstrap the cluster + core infra
# first (see README "Apply order"), then the in-cluster resources (addons, ESO).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
