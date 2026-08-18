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

  # Prefix shared by every IAM role this stack creates (eks-cluster, eks-node,
  # ebs-csi, alb-controller, external-secrets, cluster-autoscaler, github-actions).
  role_prefix = trimsuffix(var.role_name, "-github-actions")

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

  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfStateBucket"
      effect = "Allow"

      actions = [
        "s3:ListBucket",
      ]

      resources = [
        "arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfStateObject"
      effect = "Allow"

      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]

      resources = [
        "arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket}/${var.terraform_state_key}",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.terraform_lock_table != "" ? [1] : []
    content {
      sid    = "TfStateLock"
      effect = "Allow"

      actions = [
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
      ]

      resources = [
        "arn:${data.aws_partition.current.partition}:dynamodb:${coalesce(var.terraform_state_region, var.region)}:${data.aws_caller_identity.current.account_id}:table/${var.terraform_lock_table}",
      ]
    }
  }

  # ------------------------------------------------------------------------- #
  # Minimum read/refresh permissions so `terraform plan` can refresh the
  # resources managed by this stack. Scoped to this account/region and to the
  # roles the stack itself creates. Only granted together with backend access
  # (i.e. the dev role); production passes no state vars and is unchanged.
  # ------------------------------------------------------------------------- #
  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfPlanReadEcr"
      effect = "Allow"

      actions = [
        "ecr:ListTagsForResource",
      ]

      resources = [
        "arn:${data.aws_partition.current.partition}:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_namespace}/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfPlanReadIam"
      effect = "Allow"

      actions = [
        "iam:GetRole",
        "iam:GetOpenIDConnectProvider",
      ]

      resources = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.role_prefix}-*",
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com",
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfPlanReadLogs"
      effect = "Allow"

      # CloudWatch Logs Describe* actions do not support resource-level
      # permissions, so AWS requires "*" for this read action.
      actions   = ["logs:DescribeLogGroups"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfPlanReadKms"
      effect = "Allow"

      actions = [
        "kms:DescribeKey",
      ]

      resources = [
        "arn:${data.aws_partition.current.partition}:kms:${var.region}:${data.aws_caller_identity.current.account_id}:key/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.terraform_state_bucket != "" && var.terraform_state_key != "" ? [1] : []
    content {
      sid    = "TfPlanReadEc2"
      effect = "Allow"

      # EC2 Describe* actions do not support resource-level permissions, so
      # AWS requires "*" for these read actions.
      actions = [
        "ec2:DescribeVpcs",
        "ec2:DescribeAddresses",
      ]

      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}
