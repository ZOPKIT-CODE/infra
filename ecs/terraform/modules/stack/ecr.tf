locals {
  ecr_repo_names = toset(distinct([for a in local.apps : a.ecr_repo]))
  ecr_repo_urls  = var.manage_ecr ? { for k, r in aws_ecr_repository.repos : k => r.repository_url } : { for k, r in data.aws_ecr_repository.repos : k => r.repository_url }
}

data "aws_ecr_repository" "repos" {
  for_each = var.manage_ecr ? [] : local.ecr_repo_names
  name     = each.key
}

resource "aws_ecr_repository" "repos" {
  for_each = var.manage_ecr ? local.ecr_repo_names : []

  name = each.key

  image_tag_mutability = contains(var.mutable_tag_repos, each.key) ? "MUTABLE" : "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  force_delete = true

  tags = {
    Name = each.key
  }
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = var.manage_ecr ? local.ecr_repo_names : toset([])

  repository = aws_ecr_repository.repos[each.key].name

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
