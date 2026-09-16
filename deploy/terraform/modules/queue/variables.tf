variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "How long a message stays invisible after a worker picks it up."
  type        = number
  default     = 180

  validation {
    condition     = var.visibility_timeout_seconds >= 30 && var.visibility_timeout_seconds <= 43200
    error_message = "Must be between 30 and 43200 seconds."
  }
}

variable "max_receive_count" {
  description = "Deliveries a message gets before it is moved to the dead letter queue."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 2 && var.max_receive_count <= 100
    error_message = "Must be between 2 and 100. One would send a message to the dead letter queue on the first transient failure."
  }
}

variable "message_retention_seconds" {
  description = "How long an unprocessed message survives."
  type        = number
  default     = 1209600

  validation {
    condition     = var.message_retention_seconds >= 3600 && var.message_retention_seconds <= 1209600
    error_message = "Must be between 3600 and 1209600 seconds."
  }
}

variable "allow_destroy" {
  description = "Turn off deletion protection on the accept store table so the environment can be torn down."
  type        = bool
  default     = false
}
