variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated subnets the database runs in. Must span at least two availability zones."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to the database."
  type        = list(string)
}

variable "engine_version" {
  description = "PostgreSQL version. Pinned to a minor version so a rebuild produces the same engine."
  type        = string
  default     = "16.10"
}

variable "instance_class" {
  description = "Database instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in gigabytes."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper bound for storage autoscaling. Set equal to allocated_storage to switch autoscaling off."
  type        = number
  default     = 100
}

variable "backup_retention_days" {
  description = "Days of automated backups."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "Must be at least one day. Zero disables automated backups and with them point in time recovery."
  }
}

variable "backup_window" {
  description = "Daily window for automated backups, in UTC."
  type        = string
  default     = "17:00-18:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window, in UTC."
  type        = string
  default     = "sun:18:30-sun:19:30"
}

variable "database_name" {
  description = "Name of the initial database."
  type        = string
  default     = "abcsales"
}

variable "master_username" {
  description = "Master user name."
  type        = string
  default     = "abcapp"
}

variable "proxy_security_group_ids" {
  description = "Security groups attached to the proxy endpoint. Must be the group the database accepts connections from, not the database group itself."
  type        = list(string)
}

variable "create_proxy" {
  description = "Whether to create an RDS Proxy."
  type        = bool
  default     = true
}

variable "proxy_role_arn" {
  description = "Role the proxy assumes to read the master password from Secrets Manager."
  type        = string
}

variable "allow_destroy" {
  description = "Turn off deletion protection and skip the final snapshot, so the environment can be torn down in one command."
  type        = bool
  default     = false
}
