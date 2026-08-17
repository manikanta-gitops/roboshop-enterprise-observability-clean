###############################################################################
# GitHub Actions OIDC: keyless CI auth. No long-lived AWS keys in GitHub.
# Creates the OIDC provider (optional, one per account) and a CI role that can
# push to ECR and read EKS.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  # GitHub now issues immutable OIDC subject claims that embed the immutable
  # owner and repository IDs (repo:OWNER@OWNER-ID/REPO@REPO-ID:...). When the
  # IDs are supplied they are used; otherwise the legacy name-based format
  # (repo:OWNER/REPO:...) is kept for backward compatibility.
  subject_identity = (
    var.github_org_id != "" && var.github_repo_id != ""
    ? "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"
    : "repo:${var.github_org}/${var.github_repo}"
  )

  # allowed_subjects contains the suffix portion of GitHub's OIDC `sub` claim,
  # e.g. `ref:refs/heads/main` or `environment:production`.
  subjects = [for s in var.allowed_subjects : "${local.subject_identity}:${s}"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:CreateRepository",
      "ecr:DescribeImageScanFindings",
      "ecr:StartImageScan",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_namespace}/*",
    ]
  }

  dynamic "statement" {
    for_each = length(var.additional_ecr_read_repository_arns) > 0 ? [1] : []
    content {
      sid    = "EcrSourceRead"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:ListImages",
      ]
      resources = var.additional_ecr_read_repository_arns
    }
  }

  statement {
    sid    = "EksDescribe"
    effect = "Allow"

    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}
