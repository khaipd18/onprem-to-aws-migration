data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  sqs_arn_pattern       = "arn:aws:sqs:${local.region}:${local.account_id}:${var.name_prefix}-*"
  dynamodb_arn_pattern  = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.name_prefix}-*"
  parameter_arn_pattern = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.name_prefix}/*"

  secret_arn_pattern = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.name_prefix}/db/*"

  artifact_bucket_arn = "arn:aws:s3:::${var.name_prefix}-artifacts-${local.account_id}"
}

data "aws_iam_policy_document" "instance_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid    = "Queue"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [local.sqs_arn_pattern]
  }

  statement {
    sid    = "AcceptStore"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [local.dynamodb_arn_pattern]
  }

  statement {
    sid    = "Configuration"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [local.parameter_arn_pattern]
  }

  statement {
    sid    = "Decrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "ssm.${local.region}.amazonaws.com",
        "sqs.${local.region}.amazonaws.com",
        "dynamodb.${local.region}.amazonaws.com",
        "s3.${local.region}.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "Artifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [local.artifact_bucket_arn, "${local.artifact_bucket_arn}/*"]
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  description        = "Web tier, application tier and worker instances"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json

  tags = { Name = "${var.name_prefix}-instance" }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.name_prefix}-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_role_policy_attachment" "session_manager" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name

  tags = { Name = "${var.name_prefix}-instance" }
}

data "aws_iam_policy_document" "proxy_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "proxy" {
  statement {
    sid    = "ReadDatabaseCredentials"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [local.secret_arn_pattern]
  }

  statement {
    sid       = "DecryptCredentials"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name               = "${var.name_prefix}-proxy"
  description        = "Database proxy, reads the master credentials it authenticates with"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume_role.json

  tags = { Name = "${var.name_prefix}-proxy" }
}

resource "aws_iam_role_policy" "proxy" {
  name   = "${var.name_prefix}-proxy"
  role   = aws_iam_role.proxy.id
  policy = data.aws_iam_policy_document.proxy.json
}
