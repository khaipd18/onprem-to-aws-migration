variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "assets_dir" {
  description = "Local directory whose contents are uploaded to the bucket. Paths inside it become object keys."
  type        = string
}

variable "noncurrent_version_retention_days" {
  description = "Days an overwritten object version is kept before it is deleted."
  type        = number
  default     = 30
}

variable "allow_destroy" {
  description = "Let buckets be deleted while they still hold objects."
  type        = bool
  default     = false
}
