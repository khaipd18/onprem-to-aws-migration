variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "alarm_email" {
  description = "Address alarms are sent to."
  type        = string
  default     = ""
}

variable "public_alb_arn_suffix" {
  description = "Suffix CloudWatch uses to identify the internet facing load balancer."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Suffix CloudWatch uses to identify the application target group."
  type        = string
}

variable "db_instance_identifier" {
  description = "Database instance the alarms watch."
  type        = string
}

variable "db_max_connections" {
  description = "Connection ceiling of the instance class."
  type        = number
  default     = 85
}

variable "queue_name" {
  description = "Name of the order queue."
  type        = string
}

variable "dlq_name" {
  description = "Name of the dead letter queue."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group the application writes to."
  type        = string
}

variable "response_time_threshold_seconds" {
  description = "Ceiling for the ninety fifth percentile of response time. The brief sets two seconds."
  type        = number
  default     = 2
}

variable "error_rate_threshold_percent" {
  description = "Ceiling for the share of requests answered with a server error. The brief sets one percent."
  type        = number
  default     = 1
}

variable "queue_age_threshold_seconds" {
  description = "How old the oldest unprocessed message may get before the alarm fires."
  type        = number
  default     = 300
}
