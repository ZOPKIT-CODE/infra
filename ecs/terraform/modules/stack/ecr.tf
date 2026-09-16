# ecr.tf
# ECR repositories for the suite backend images (wrapper, crm, fa).
#
# The repository set is derived from local.apps[*].ecr_repo and de-duplicated,
# yielding exactly: "wrapper-backend", "crm-backend", "fa-backend".
# outputs.tf consumes aws_ecr_repository.repos[<reponame>].repository_url.

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

  name = each.key

  # IMMUTABLE by default — that is what makes a rollback trustworthy and what the
  # deploy pipeline's "tag already in ECR, skip the build" guard relies on.
  #
  # Per-repo opt-out for apps still publishing a MOVING tag. Adopting
  # entertainment-erp-backend (which republishes :staging on every deploy) flipped
  # it to IMMUTABLE and would have made its very next push fail — an immutable repo
  # rejects a re-pushed tag. Onboarding order is: switch the app to git-SHA tags
  # FIRST, then drop it from this set. See deploy/ecs/ONBOARDING.md, A1/A2.
  image_tag_mutability = contains(var.mutable_tag_repos, each.key) ? "MUTABLE" : "IMMUTABLE"

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
  # Keyed off the NAME set, not off aws_ecr_repository.repos. Deriving for_each
  # from another resource's attributes makes the key set unknown until apply,
  # which breaks `terraform import` for unrelated resources in this stack
  # ("Invalid for_each argument ... will be known only after apply"). The keys
  # are identical either way (local.ecr_repo_names is that resource's for_each),
  # so this is address-stable — no state moves needed.
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
