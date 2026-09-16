output "topic_arn" {
  description = "Topic every alarm publishes to."
  value       = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  description = "Every alarm this module creates."
  value = [
    aws_cloudwatch_metric_alarm.response_time.alarm_name,
    aws_cloudwatch_metric_alarm.error_rate.alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name,
    aws_cloudwatch_metric_alarm.db_connections.alarm_name,
    aws_cloudwatch_metric_alarm.db_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.db_storage.alarm_name,
    aws_cloudwatch_metric_alarm.queue_backlog.alarm_name,
    aws_cloudwatch_metric_alarm.dlq_not_empty.alarm_name,
  ]
}

output "dashboard_name" {
  description = "Dashboard showing the numbers the brief sets thresholds on."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "subscription_pending" {
  description = "True when an email subscription was created. It stays pending until someone clicks the confirmation link, and alarms reach nobody before that."
  value       = var.alarm_email != ""
}
