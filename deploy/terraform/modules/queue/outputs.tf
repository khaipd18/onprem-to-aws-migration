output "queue_url" {
  description = "URL of the order queue."
  value       = aws_sqs_queue.orders.id
}

output "queue_arn" {
  description = "ARN of the order queue."
  value       = aws_sqs_queue.orders.arn
}

output "queue_name" {
  description = "Name of the order queue."
  value       = aws_sqs_queue.orders.name
}

output "dlq_url" {
  description = "URL of the dead letter queue."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the dead letter queue."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Name of the dead letter queue."
  value       = aws_sqs_queue.dlq.name
}

output "accept_table_name" {
  description = "DynamoDB table holding accepted order records."
  value       = aws_dynamodb_table.accept.name
}

output "accept_table_arn" {
  description = "ARN of the accept store table."
  value       = aws_dynamodb_table.accept.arn
}
