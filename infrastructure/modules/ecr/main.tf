###############################################################################
# ECR module: one private repository per service, scan-on-push, lifecycle rules.
###############################################################################

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.namespace}/${each.value}"
  image_tag_mutability = var.image_tag_mutability
  force_delete          = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Name = "${var.namespace}/${each.value}" })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last ${var.keep_last_images} release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.release_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_last_images
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after ${var.untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Allow the EKS node role (and any extra principals) to pull images.
data "aws_iam_policy_document" "pull" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "pull" {
  for_each = length(var.pull_principal_arns) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name
  policy     = data.aws_iam_policy_document.pull[0].json
}

