variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}
