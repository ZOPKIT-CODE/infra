# ---------------------------------------------------------------------------
# Core substrate: VPC + EKS (community modules). Leaf .tf files reference
# module.vpc.* and module.eks.* and the locals defined in locals.tf.
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private (apps), /24 public (ALB/NAT), /24 intra (ElastiCache/internal).
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
  intra_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 96)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required by the AWS Load Balancer Controller for subnet auto-discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                         = "1"
    "kubernetes.io/cluster/${local.name_prefix}-eks" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                = "1"
    "kubernetes.io/cluster/${local.name_prefix}-eks" = "shared"
  }

  tags = local.common_tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = "${local.name_prefix}-eks"
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = var.cluster_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_public_access_cidrs
  cluster_endpoint_private_access      = true

  enable_irsa = true # OIDC provider for IAM Roles for Service Accounts

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Grant the applying principal admin so kubernetes/helm providers work post-create.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true, service_account_role_arn = module.ebs_csi_irsa.iam_role_arn }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_group_defaults = {
    ami_type      = "AL2023_x86_64_STANDARD"
    capacity_type = var.node_capacity_type # ON_DEMAND (prod) | SPOT (staging/dev — ~70% cheaper)
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_group_min
      max_size       = var.node_group_max
      desired_size   = var.node_group_desired
      labels         = { "workload" = "general" }
    }
  }

  access_entries = {
    for idx, arn in var.cluster_admin_role_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = local.common_tags
}

# IRSA for the EBS CSI driver addon (referenced above).
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${local.name_prefix}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.common_tags
}

# The app namespace (created early so ExternalSecrets/ServiceAccounts can target it).
resource "kubernetes_namespace" "app" {
  metadata {
    name = local.namespace
    labels = {
      environment                    = var.environment
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  depends_on = [module.eks]
}
