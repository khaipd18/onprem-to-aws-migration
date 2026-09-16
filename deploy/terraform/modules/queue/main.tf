resource "aws_sqs_queue" "dlq" {
  name       = "${var.name_prefix}-orders-dlq.fifo"
  fifo_queue = true

  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = { Name = "${var.name_prefix}-orders-dlq" }
}

resource "aws_sqs_queue" "orders" {
  name       = "${var.name_prefix}-orders.fifo"
  fifo_queue = true

  content_based_deduplication = false
  deduplication_scope         = "messageGroup"
  fifo_throughput_limit       = "perMessageGroupId"

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20
  max_message_size           = 262144
  delay_seconds              = 0

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = { Name = "${var.name_prefix}-orders" }
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders.arn]
  })
}
