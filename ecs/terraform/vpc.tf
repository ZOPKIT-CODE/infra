# ---------------------------------------------------------------------------
# Core network substrate: VPC only (no EKS in this stack). Leaf .tf files
# reference module.vpc.* and the locals defined in locals.tf.
#
# Subnet layout (same CIDR math as the EKS stack so addresses stay comparable):
#   /20 private  (Fargate tasks when fargate_assign_public_ip = false)
#   /24 public   (ALB; also Fargate tasks when fargate_assign_public_ip = true)
#   /24 intra    (ElastiCache Valkey — private, no NAT)
#
# Cost toggle: when fargate_assign_public_ip = true (default), tasks live in the
# public subnets with a public IP for ECR/Secrets/AWS egress and we provision NO
# NAT gateway. Set fargate_assign_public_ip = false to run tasks in the private
# subnets behind NAT (prod-private), optionally single_nat_gateway for cost.
#
# No kubernetes.io/* subnet tags: the ALB here is created explicitly (alb.tf),
# not auto-discovered by an in-cluster controller.
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
  intra_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 96)]

  # NAT-less when tasks run in public subnets (cheapest). When tasks are private,
  # provision NAT (single or per-AZ per var.single_nat_gateway).
  enable_nat_gateway   = var.fargate_assign_public_ip ? false : true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}
