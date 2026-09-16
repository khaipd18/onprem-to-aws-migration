resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "${var.name_prefix}-app-errors"
  log_group_name = var.log_group_name

  pattern = "{ ($.level = \"ERROR\") || ($.level = \"CRITICAL\") }"

  metric_transformation {
    name      = "ApplicationErrors"
    namespace = "ABCSales/${var.name_prefix}"
    value     = "1"
    unit      = "Count"

    dimensions = {
      Tier = "$.tier"
    }
  }
}

resource "aws_cloudwatch_query_definition" "trace_by_correlation_id" {
  name = "${var.name_prefix}/truy-vet-mot-giao-dich"

  log_group_names = [var.log_group_name]

  query_string = <<-QUERY
    fields @timestamp, tier, instance, event, order_id, @message
    | filter correlation_id = "DAN_CORRELATION_ID_VAO_DAY"
    | sort @timestamp asc
    | limit 200
  QUERY
}

resource "aws_cloudwatch_query_definition" "trace_by_order_id" {
  name = "${var.name_prefix}/truy-vet-theo-ma-don"

  log_group_names = [var.log_group_name]

  query_string = <<-QUERY
    fields @timestamp, tier, instance, event, correlation_id, @message
    | filter order_id = "DAN_ORDER_ID_VAO_DAY"
    | sort @timestamp asc
    | limit 200
  QUERY
}

resource "aws_cloudwatch_query_definition" "errors_last_hour" {
  name = "${var.name_prefix}/loi-gan-day"

  log_group_names = [var.log_group_name]

  query_string = <<-QUERY
    fields @timestamp, tier, instance, logger, msg
    | filter level in ["ERROR", "CRITICAL"]
    | sort @timestamp desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_query_definition" "slow_requests" {
  name = "${var.name_prefix}/request-cham"

  log_group_names = [var.log_group_name]

  query_string = <<-QUERY
    fields @timestamp, tier, event, duration_ms, correlation_id, order_id
    | filter ispresent(duration_ms) and duration_ms > 1000
    | sort duration_ms desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name_prefix

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Thoi gian phan hoi (nguong p95 = ${var.response_time_threshold_seconds}s)"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "p95"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", var.public_alb_arn_suffix,
            "TargetGroup", var.target_group_arn_suffix],
          ]
          annotations = {
            horizontal = [{ label = "nguong de bai", value = var.response_time_threshold_seconds }]
          }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Request va loi may chu"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",
              "LoadBalancer", var.public_alb_arn_suffix,
            "TargetGroup", var.target_group_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
              "LoadBalancer", var.public_alb_arn_suffix,
            "TargetGroup", var.target_group_arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Hang doi: ton dong va tuoi tin nhan cu nhat"
          region = data.aws_region.current.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.queue_name, { stat = "Maximum" }],
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", var.queue_name, { stat = "Maximum", yAxis = "right" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_name, { stat = "Maximum", label = "DLQ" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Database"
          region = data.aws_region.current.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_identifier, { stat = "Average" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_identifier, { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Instance khoe manh va khong khoe"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount",
              "LoadBalancer", var.public_alb_arn_suffix,
            "TargetGroup", var.target_group_arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount",
              "LoadBalancer", var.public_alb_arn_suffix,
            "TargetGroup", var.target_group_arn_suffix],
          ]
        }
      },
    ]
  })
}

data "aws_region" "current" {}
