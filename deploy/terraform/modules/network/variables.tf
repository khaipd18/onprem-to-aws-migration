variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "region" {
  description = "Region the VPC lives in. Used to name the S3 endpoint service."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
}

variable "public_subnets" {
  description = "Public subnets, keyed by availability zone. Hosts the load balancer and the NAT gateway."
  type        = map(string)
}

variable "private_subnets" {
  description = "Private subnets, keyed by availability zone. Hosts the application instances."
  type        = map(string)
}

variable "data_subnets" {
  description = "Isolated subnets, keyed by availability zone. Hosts the database and the file server."
  type        = map(string)
}

variable "nat_az" {
  description = "Availability zone holding the single NAT gateway. Must be one of the public subnet keys."
  type        = string
  default     = "ap-southeast-1a"
}
