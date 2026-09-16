locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    var.extra_tags,
    {
      owner       = var.owner
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
  )
}
