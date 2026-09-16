variable "name_prefix" {
  description = "Prefix applied to every resource name in this module."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated subnets the mount targets live in, one per availability zone."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to the mount targets. Must allow port 2049 from the application tier."
  type        = list(string)
}

variable "departments" {
  description = "Departments that get their own access point."
  type = map(object({
    uid = number
    gid = number
  }))
  default = {
    sales      = { uid = 6001, gid = 5001 }
    finance    = { uid = 6002, gid = 5002 }
    hr         = { uid = 6003, gid = 5003 }
    production = { uid = 6004, gid = 5004 }
    purchasing = { uid = 6005, gid = 5005 }
  }
}

variable "shared_gid" {
  description = "Group every department belongs to, for the folder the whole company can read."
  type        = number
  default     = 5000
}

variable "transition_to_ia_days" {
  description = "Days a file goes untouched before it moves to the cheaper infrequent access class."
  type        = number
  default     = 30
}
