###############################################################################
# Backup module - AWS Backup for the EBS volumes behind the datastore PVCs.
#
# No extra product to run or upgrade: AWS Backup is managed, it snapshots the
# same EBS volumes the EBS CSI driver provisions, and restore is a console/CLI
# operation. Volumes opt in through a tag, which the production StorageClass
# stamps on every volume it creates (tagSpecification_1 = "backup=daily").
###############################################################################

resource "aws_backup_vault" "this" {
  name = "${var.project}-${var.environment}"
  tags = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.project}-${var.environment}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "this" {
  name = "${var.project}-${var.environment}-ebs"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.daily_schedule # default 01:00 UTC
    start_window      = 60
    completion_window = 240

    lifecycle {
      delete_after = var.daily_retention_days
    }

    recovery_point_tags = merge(var.tags, { BackupRule = "daily" })
  }

  dynamic "rule" {
    for_each = var.weekly_retention_days > 0 ? [1] : []
    content {
      rule_name         = "weekly"
      target_vault_name = aws_backup_vault.this.name
      schedule          = var.weekly_schedule # default Sun 02:00 UTC
      start_window      = 60
      completion_window = 480

      lifecycle {
        delete_after = var.weekly_retention_days
      }

      recovery_point_tags = merge(var.tags, { BackupRule = "weekly" })
    }
  }

  tags = var.tags
}

resource "aws_backup_selection" "tagged_volumes" {
  name         = "${var.project}-${var.environment}-tagged-ebs"
  iam_role_arn = aws_iam_role.this.arn
  plan_id      = aws_backup_plan.this.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.selection_tag_key
    value = var.selection_tag_value
  }
}
