resource "aws_iam_openid_connect_provider" "github" {
  count           = var.enable_ci_oidc ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  tags            = var.tags
}

data "aws_iam_policy_document" "github_deploy_trust" {
  count = var.enable_ci_oidc ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([
        for r in var.github_deploy_repos : [
          "repo:${r}:*",
          "repo:${split("/", r)[0]}@*/${split("/", r)[1]}@*:*",
        ]
      ])
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count              = var.enable_ci_oidc ? 1 : 0
  name               = "${var.name_prefix}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_trust[0].json
  tags               = var.tags
}

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
    resources = ["arn:aws:iam::${var.account_id}:role/${var.name_prefix}-*"]
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
    resources = ["arn:aws:s3:::zopkit-tfstate-${var.account_id}", "arn:aws:s3:::zopkit-tfstate-${var.account_id}/*"]
  }
  statement {
    sid       = "FrontendAndMediaBuckets"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.name_prefix}-*", "arn:aws:s3:::${var.name_prefix}-*/*", "arn:aws:s3:::wrapper-tenant-logos", "arn:aws:s3:::wrapper-tenant-logos/*", "arn:aws:s3:::zopkit-prod-wrapper-fe", "arn:aws:s3:::zopkit-prod-wrapper-fe/*"]
  }
  statement {
    sid       = "CloudFrontInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:GetDistribution", "cloudfront:ListDistributions"]
    resources = ["*"]
  }
  statement {
    sid       = "DeployedTagParams"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/${var.project}/*/deployed-tag/*"]
  }
  statement {
    sid    = "RefreshReadOnly"
    effect = "Allow"
    actions = [
      "ec2:Describe*", "logs:Describe*", "logs:ListTags*", "logs:CreateLogGroup", "logs:PutRetentionPolicy",
      "sns:Get*", "sns:List*", "sqs:Get*", "sqs:List*", "route53:Get*", "route53:List*",
      "cognito-idp:Describe*", "cognito-idp:Get*", "cognito-idp:List*", "elasticache:Describe*", "elasticache:List*",
      "acm:Describe*", "acm:List*", "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecret*",
      "s3:Get*", "s3:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count  = var.enable_ci_oidc ? 1 : 0
  name   = "deploy"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy.json
}

data "aws_iam_policy_document" "infra_apply_trust" {
  count = var.enable_ci_oidc ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:ZOPKIT-CODE/Wrapper:environment:infra-*",
        "repo:ZOPKIT-CODE/infra:environment:infra-*",
        "repo:ZOPKIT-CODE@*/Wrapper@*:environment:infra-*",
        "repo:ZOPKIT-CODE@*/infra@*:environment:infra-*",
      ]
    }
  }
}

data "aws_iam_policy_document" "infra_apply" {
  count = var.enable_ci_oidc ? 1 : 0

  statement {
    sid    = "InfraServices"
    effect = "Allow"
    actions = [
      "ec2:*", "ecs:*", "ecr:*", "elasticloadbalancing:*", "application-autoscaling:*",
      "sns:*", "sqs:*", "elasticache:*", "cloudfront:*", "cognito-idp:*",
      "route53:*", "acm:*", "logs:*", "cloudwatch:*", "s3:*", "secretsmanager:*", "ses:*",
      "kms:DescribeKey", "kms:ListAliases", "kms:CreateGrant",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "IamProjectScoped"
    effect    = "Allow"
    actions   = ["iam:*"]
    resources = ["arn:aws:iam::${var.account_id}:role/${var.project}-*", "arn:aws:iam::${var.account_id}:policy/${var.project}-*"]
  }
  statement {
    sid       = "IamOidcProvider"
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider"]
    resources = [aws_iam_openid_connect_provider.github[0].arn]
  }
  statement {
    sid       = "IamReadAndPassRole"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*", "iam:PassRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "infra_apply" {
  count              = var.enable_ci_oidc ? 1 : 0
  name               = "${var.project}-infra-apply"
  assume_role_policy = data.aws_iam_policy_document.infra_apply_trust[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "infra_apply" {
  count  = var.enable_ci_oidc ? 1 : 0
  name   = "infra-apply"
  role   = aws_iam_role.infra_apply[0].id
  policy = data.aws_iam_policy_document.infra_apply[0].json
}
