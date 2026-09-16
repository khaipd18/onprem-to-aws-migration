locals {
  dms_service_roles = {
    "dms-vpc-role"             = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
    "dms-cloudwatch-logs-role" = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
  }
}

data "aws_iam_policy_document" "dms_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dms.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dms_service" {
  for_each = var.create_service_roles ? local.dms_service_roles : {}

  name               = each.key
  assume_role_policy = data.aws_iam_policy_document.dms_assume_role.json

  tags = { Name = each.key }
}

resource "aws_iam_role_policy_attachment" "dms_service" {
  for_each = var.create_service_roles ? local.dms_service_roles : {}

  role       = aws_iam_role.dms_service[each.key].name
  policy_arn = each.value
}
