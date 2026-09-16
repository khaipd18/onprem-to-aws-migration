resource "aws_efs_file_system" "main" {
  creation_token = var.name_prefix
  encrypted      = true

  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_${var.transition_to_ia_days}_DAYS"
  }

  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = { Name = "${var.name_prefix}-files" }
}

resource "aws_efs_mount_target" "main" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = var.security_group_ids
}

resource "aws_efs_access_point" "department" {
  for_each = var.departments

  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = each.value.uid
    gid = each.value.gid
  }

  root_directory {
    path = "/${each.key}"

    creation_info {
      owner_uid   = each.value.uid
      owner_gid   = each.value.gid
      permissions = "0770"
    }
  }

  tags = {
    Name       = "${var.name_prefix}-${each.key}"
    Department = each.key
  }
}

resource "aws_efs_access_point" "shared" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid            = 6000
    gid            = var.shared_gid
    secondary_gids = [for d in var.departments : d.gid]
  }

  root_directory {
    path = "/public"

    creation_info {
      owner_uid   = 6000
      owner_gid   = var.shared_gid
      permissions = "0775"
    }
  }

  tags = { Name = "${var.name_prefix}-public" }
}

data "aws_iam_policy_document" "main" {
  statement {
    sid    = "RequireTlsAndIamAuth"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["elasticfilesystem:*"]
    resources = [aws_efs_file_system.main.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowMountThroughAccessPointsOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]

    resources = [aws_efs_file_system.main.arn]

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values = concat(
        [for a in aws_efs_access_point.department : a.arn],
        [aws_efs_access_point.shared.arn],
      )
    }
  }
}

resource "aws_efs_file_system_policy" "main" {
  file_system_id                     = aws_efs_file_system.main.id
  policy                             = data.aws_iam_policy_document.main.json
  bypass_policy_lockout_safety_check = false
}

resource "aws_efs_backup_policy" "main" {
  file_system_id = aws_efs_file_system.main.id

  backup_policy {
    status = "ENABLED"
  }
}
