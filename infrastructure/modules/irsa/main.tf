###############################################################################
# Generic IRSA module: an IAM role a Kubernetes ServiceAccount can assume
# through the cluster OIDC provider.
###############################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${var.oidc_provider_url}:sub"
      values   = [for sa in var.service_accounts : "system:serviceaccount:${sa}"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = var.description
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy_json == "" ? 0 : 1

  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}
