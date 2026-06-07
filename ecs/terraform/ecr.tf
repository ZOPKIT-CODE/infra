# ecr.tf
# ECR repositories for the suite backend images (wrapper, crm, fa).
#
# The repository set is derived from local.apps[*].ecr_repo and de-duplicated,
# yielding exactly: "wrapper-backend", "crm-backend", "fa-backend".
# outputs.tf consumes aws_ecr_repository.repos[<reponame>].repository_url.

# ECR repos are NOT env-prefixed (image names are shared across environments), so
# exactly ONE workspace creates them; others reference them. Toggle with manage_ecr.
variable "manage_ecr" {
  description = "Create the shared ECR repositories (true) or look them up (false). One env owns them; secondary envs (e.g. prod) reference the same images."
  type        = bool
  default     = true
}

locals {
  ecr_repo_names = toset(distinct([for a in local.apps : a.ecr_repo]))
  # Resolve repo URLs from whichever source is active, so consumers don't branch.
  ecr_repo_urls = var.manage_ecr ? { for k, r in aws_ecr_repository.repos : k => r.repository_url } : { for k, r in data.aws_ecr_repository.repos : k => r.repository_url }
}

# Look up the shared repos when this env doesn't manage them.
data "aws_ecr_repository" "repos" {
  for_each = var.manage_ecr ? [] : local.ecr_repo_names
  name     = each.key
}

# One immutable, scan-on-push, AES256-encrypted repository per distinct app image.
resource "aws_ecr_repository" "repos" {
  for_each = var.manage_ecr ? local.ecr_repo_names : []

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"

  # Scan every pushed image for known CVEs.
  image_scanning_configuration {
    scan_on_push = true
  }

  # AWS-managed encryption at rest.
  encryption_configuration {
    encryption_type = "AES256"
  }

  # Allow `terraform destroy` to remove repos that still contain images.
  force_delete = true

  tags = {
    Name = each.key
  }
}

# Lifecycle policy per repo:
#   rule 1 — keep only the last 20 tagged images (any tag prefix),
#   rule 2 — expire untagged images after 7 days.
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha", "latest", "prod"]
          countType     = "imageCountMoreThan"
          countNumber   = 20
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
