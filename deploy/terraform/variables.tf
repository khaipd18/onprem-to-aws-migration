variable "aws_profile" {
  description = "AWS CLI profile used for every API call."
  type        = string
  default     = "abc-migration"
}

variable "aws_region" {
  description = "Region where all resources are created."
  type        = string
  default     = "ap-southeast-1"
}

variable "expected_account_id" {
  description = "Only account the stack is allowed to run in. Terraform stops before touching anything when the profile resolves to a different account."
  type        = string
  default     = "123456789012"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Must be a 12 digit account id."
  }
}

variable "project" {
  description = "Project name. Used as a tag and as the prefix of every resource name."
  type        = string
  default     = "abc-migration"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.project))
    error_message = "Must be 2-20 characters of lowercase letters, digits and hyphens, starting with a letter. The cap leaves room within the 32-character limit on load balancer and target group names."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Person accountable for the resources. Required tag on every resource."
  type        = string
  default     = "khaipd18"

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "Must not be empty. Every resource is required to carry an owner tag."
  }
}

variable "extra_tags" {
  description = "Additional tags merged into the common tag set."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.extra_tags), "owner")
    error_message = "Must not contain owner. Set the owner variable instead so the tag has a single source."
  }
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Public subnets, keyed by availability zone."
  type        = map(string)
  default = {
    "ap-southeast-1a" = "10.0.0.0/24"
    "ap-southeast-1b" = "10.0.1.0/24"
  }
}

variable "private_subnets" {
  description = "Private subnets for the application tier, keyed by availability zone."
  type        = map(string)
  default = {
    "ap-southeast-1a" = "10.0.10.0/24"
    "ap-southeast-1b" = "10.0.11.0/24"
  }
}

variable "data_subnets" {
  description = "Isolated subnets for the database and file server, keyed by availability zone."
  type        = map(string)
  default = {
    "ap-southeast-1a" = "10.0.20.0/24"
    "ap-southeast-1b" = "10.0.21.0/24"
  }
}

variable "create_rds_proxy" {
  description = "Whether to create an RDS Proxy."
  type        = bool
  default     = true
}

variable "allow_destroy" {
  description = "Make the whole stack removable in one command."
  type        = bool
  default     = false
}

variable "assets_dir" {
  description = "Local directory holding the built front end."
  type        = string
  default     = "../../build/spa"
}

variable "create_cloudfront" {
  description = "Whether to create the CloudFront distribution."
  type        = bool
  default     = false
}

variable "alb_domain_name" {
  description = "DNS name of the public load balancer. Required when create_cloudfront is on."
  type        = string
  default     = ""
}

variable "queue_visibility_timeout_seconds" {
  description = "How long a message stays invisible after a worker picks it up."
  type        = number
  default     = 180
}

variable "queue_max_receive_count" {
  description = "Deliveries a message gets before it is moved to the dead letter queue."
  type        = number
  default     = 5
}

variable "instance_type" {
  description = "Instance type for the application tier."
  type        = string
  default     = "t4g.small"
}

variable "warm_pool_size" {
  description = "Stopped instances kept ready so a scale out takes seconds instead of minutes."
  type        = number
  default     = 2
}

variable "accept_store_driver" {
  description = "Where accepted orders are recorded before they reach the database. Use dynamodb on AWS so the record survives a database outage."
  type        = string
  default     = "dynamodb"

  validation {
    condition     = contains(["dynamodb", "pg"], var.accept_store_driver)
    error_message = "Must be dynamodb or pg."
  }
}

variable "alarm_email" {
  description = "Address alarms are sent to. The subscription stays pending until it is confirmed from the inbox."
  type        = string
  default     = ""
}

variable "create_migration" {
  description = "Whether to create the migration tooling."
  type        = bool
  default     = false
}

variable "create_dms_service_roles" {
  description = "Whether to create dms-vpc-role and dms-cloudwatch-logs-role. DMS requires both under these exact names and they are shared by the whole account, so leave this off when they already exist."
  type        = bool
  default     = false
}

variable "migration_source_db" {
  description = "Connection details of the database being migrated away from."
  type = object({
    host     = string
    port     = number
    database = string
    username = string
    password = string
  })
  sensitive = true
  default = {
    host     = ""
    port     = 5432
    database = "abcsales"
    username = "abcapp"
    password = ""
  }
}

variable "db_master_username" {
  description = "Master user of the target database."
  type        = string
  default     = "abcapp"
}

variable "migration_files_bucket_arn" {
  description = "Bucket holding the file share staged out of the source server."
  type        = string
  default     = ""
}

variable "datasync_role_arn" {
  description = "Role DataSync assumes to read the staging bucket."
  type        = string
  default     = ""
}
