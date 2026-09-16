variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "alb_domain_name" {
  description = "DNS name of the public load balancer, used as the origin for everything that is not a static asset."
  type        = string
}

variable "assets_bucket_regional_domain_name" {
  description = "Regional domain name of the asset bucket, used as the origin for /static/*."
  type        = string
}

variable "price_class" {
  description = "Edge locations the distribution uses."
  type        = string
  default     = "PriceClass_200"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "Must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "origin_protocol_policy" {
  description = "How the distribution talks to the load balancer. Set to https-only once the load balancer has a certificate."
  type        = string
  default     = "http-only"

  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.origin_protocol_policy)
    error_message = "Must be http-only, https-only or match-viewer."
  }
}

variable "assets_bucket_id" {
  description = "Name of the bucket holding the front end."
  type        = string
}

variable "assets_bucket_arn" {
  description = "ARN of the asset bucket."
  type        = string
}
