variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the replication instance runs in. Must reach both the source database and the target database."
  type        = list(string)
}

variable "subnet_arns" {
  description = "Subnet ARNs, the form the file copy location expects."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "Security groups attached to the replication instance."
  type        = list(string)
}

variable "security_group_arns" {
  description = "Security group ARNs, the form the file copy location expects."
  type        = list(string)
  default     = []
}

variable "instance_class" {
  description = "Replication instance class."
  type        = string
  default     = "dms.t3.micro"
}

variable "allocated_storage" {
  description = "Storage for the replication instance, in gigabytes. Fifty is the minimum the service accepts."
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Whether the replication instance runs across two availability zones."
  type        = bool
  default     = false
}

variable "source_db" {
  description = "Connection details of the database being migrated away from."
  type = object({
    host     = string
    port     = number
    database = string
    username = string
    password = string
  })
  sensitive = true
}

variable "target_db" {
  description = "Connection details of the database being migrated to."
  type = object({
    host     = string
    port     = number
    database = string
    username = string
    password = string
  })
  sensitive = true
}

variable "migrated_tables" {
  description = "Tables carried across."
  type        = list(string)
  default     = ["customers", "products", "orders", "order_items", "order_events"]
}

variable "enable_file_migration" {
  description = "Whether to create the file copy task."
  type        = bool
  default     = false
}

variable "source_files_bucket_arn" {
  description = "Bucket holding the file share staged out of the source server. Leave empty to skip the file part."
  type        = string
  default     = ""
}

variable "target_efs_arn" {
  description = "File system the files are copied into."
  type        = string
  default     = ""
}

variable "datasync_role_arn" {
  description = "Role DataSync assumes to read the staging bucket. Required when the file part is enabled."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Days CloudWatch keeps the migration logs."
  type        = number
  default     = 30
}

variable "create_service_roles" {
  description = "Whether to create the two roles DMS requires under fixed names. They are shared by the whole account, so leave this off when another stack already owns them."
  type        = bool
  default     = false
}
