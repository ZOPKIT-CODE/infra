# ecr.tf
# ECR repositories for the suite backend images (wrapper, crm, fa).
#
# The repository set is derived from local.apps[*].ecr_repo and de-duplicated,
# yielding exactly: "wrapper-backend", "crm-backend", "fa-backend".
# outputs.tf consumes aws_ecr_repository.repos[<reponame>].repository_url.

# One immutable, scan-on-push, AES256-encrypted repository per distinct app image.
resource "aws_ecr_repository" "repos" {
  for_each = toset(distinct([for a in local.apps : a.ecr_repo]))

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
