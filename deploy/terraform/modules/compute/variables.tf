variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC the load balancer and instances run in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets holding the internet facing load balancer."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets holding the application instances."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group of the public load balancer."
  type        = string
}

variable "app_security_group_id" {
  description = "Security group of the application instances."
  type        = string
}

variable "instance_profile_name" {
  description = "Instance profile giving the instances their permissions."
  type        = string
}

variable "instance_type" {
  description = "Instance type. Graviton is about twenty percent cheaper and the application is pure Python."
  type        = string
  default     = "t4g.small"
}

variable "app_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8080
}

variable "min_size" {
  description = "Fewest instances the group keeps running."
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Instances the group starts with. Target tracking adjusts it afterwards."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Most instances the group scales out to."
  type        = number
  default     = 6
}

variable "warm_pool_size" {
  description = "Stopped instances kept ready so a scale out takes seconds instead of minutes."
  type        = number
  default     = 2
}

variable "requests_per_target" {
  description = "Target tracking goal: requests per minute each instance should carry before the group scales out."
  type        = number
  default     = 600
}

variable "log_retention_days" {
  description = "Days CloudWatch keeps application logs."
  type        = number
  default     = 30
}

variable "allowed_origins" {
  description = "Origins the application accepts browser requests from."
  type        = string
  default     = "*"
}

variable "accept_store_driver" {
  description = "Where accepted orders are recorded before they reach the database."
  type        = string
  default     = "dynamodb"
}

variable "accept_store_name" {
  description = "DynamoDB table holding accepted order records."
  type        = string
  default     = ""
}

variable "queue_url" {
  description = "URL of the order queue."
  type        = string
}

variable "dlq_url" {
  description = "URL of the dead letter queue."
  type        = string
}

variable "propagated_tags" {
  description = "Tags copied onto every instance the group launches."
  type        = map(string)
  default     = {}
}

variable "allow_destroy" {
  description = "Let buckets be deleted while they still hold objects."
  type        = bool
  default     = false
}

variable "visibility_timeout_seconds" {
  description = "How long a message stays invisible after a worker picks it up. Must match the queue setting."
  type        = number
  default     = 180
}

variable "max_receive_count" {
  description = "Deliveries a message gets before it is moved to the dead letter queue. Must match the queue setting."
  type        = number
  default     = 5
}
