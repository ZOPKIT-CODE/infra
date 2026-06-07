# ci-oidc.tf
# GitHub Actions → AWS via OIDC (no long-lived keys). Creates the GitHub OIDC
# provider + a single deploy role the app repos assume to build/push images and
# run `terraform apply -target` + ECS deploys. Trust is scoped to the listed repos.

variable "github_deploy_repos" {
  description = "owner/repo allowed to assume the deploy role via OIDC."
  type        = list(string)
  default = [
    "ZOPKIT-CODE/Wrapper",
    "ZOPKIT-CODE/B2B-CRM",
    "ZOPKIT-CODE/Finance-Accounting",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  tags            = local.common_tags
}

data "aws_iam_policy_document" "github_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for r in var.github_deploy_repos : "repo:${r}:*"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${local.name_prefix}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_trust.json
  tags               = local.common_tags
}

# Deploy permissions: build/push images, run terraform apply -target (ECS service
# + task def + autoscaling + ALB target group/rule), run the migration task,
# deploy the frontend (S3 + CloudFront), and the read access terraform refresh needs.
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrPushPull"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListImages", "ecr:ListTagsForResource"]
    resources = ["*"]
  }
  statement {
    sid       = "EcsDeploy"
    effect    = "Allow"
    actions   = ["ecs:*", "application-autoscaling:*", "elasticloadbalancing:*"]
    resources = ["*"]
  }
  statement {
    sid       = "PassTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.name_prefix}-*"]
  }
  statement {
    sid       = "IamRead"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetOpenIDConnectProvider", "iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = ["*"]
  }
  statement {
    sid       = "StateBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketVersioning"]
    resources = ["arn:aws:s3:::zopkit-tfstate-${local.account_id}", "arn:aws:s3:::zopkit-tfstate-${local.account_id}/*"]
  }
  statement {
    sid       = "FrontendAndMediaBuckets"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${local.name_prefix}-*", "arn:aws:s3:::${local.name_prefix}-*/*", "arn:aws:s3:::wrapper-tenant-logos", "arn:aws:s3:::wrapper-tenant-logos/*"]
  }
  statement {
    sid       = "CloudFrontInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:GetDistribution", "cloudfront:ListDistributions"]
    resources = ["*"]
  }
  # Read-only access terraform's refresh needs across the rest of the stack.
  statement {
    sid    = "RefreshReadOnly"
    effect = "Allow"
    actions = [
      "ec2:Describe*", "logs:Describe*", "logs:ListTags*", "logs:CreateLogGroup", "logs:PutRetentionPolicy",
      "sns:Get*", "sns:List*", "sqs:Get*", "sqs:List*", "route53:Get*", "route53:List*",
      "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*", "elasticache:Describe*", "elasticache:List*",
      "acm:Describe*", "acm:List*", "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecret*",
      # S3 read-only: terraform refresh reads ~12 per-bucket sub-configs (accelerate, cors,
      # website, logging, acl, object-lock, public-access-block, tagging, …) whose IAM action
      # names are NOT all under s3:GetBucket* — grant the read verbs broadly to avoid whack-a-mole.
      "s3:Get*", "s3:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

output "github_deploy_role_arn" {
  description = "ARN to put in each repo's GitHub Actions workflow (role-to-assume)."
  value       = aws_iam_role.github_deploy.arn
}
