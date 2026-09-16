data "aws_caller_identity" "current" {}

locals {
  bucket_suffix = data.aws_caller_identity.current.account_id

  content_types = {
    html  = "text/html; charset=utf-8"
    txt   = "text/plain; charset=utf-8"
    map   = "application/json"
    png   = "image/png"
    jpg   = "image/jpeg"
    jpeg  = "image/jpeg"
    svg   = "image/svg+xml"
    webp  = "image/webp"
    ico   = "image/x-icon"
    css   = "text/css"
    js    = "text/javascript"
    json  = "application/json"
    woff2 = "font/woff2"
  }

  assets = fileset(var.assets_dir, "**/*")
}

resource "aws_s3_bucket" "assets" {
  bucket        = "${var.name_prefix}-assets-${local.bucket_suffix}"
  force_destroy = var.allow_destroy

  tags = { Name = "${var.name_prefix}-assets" }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.assets]
}

resource "aws_s3_object" "assets" {
  for_each = local.assets

  bucket       = aws_s3_bucket.assets.id
  key          = each.value
  source       = "${var.assets_dir}/${each.value}"
  etag         = filemd5("${var.assets_dir}/${each.value}")
  content_type = lookup(local.content_types, lower(reverse(split(".", each.value))[0]), "application/octet-stream")

  cache_control = each.value == "index.html" ? "no-cache" : "public, max-age=31536000, immutable"

  tags = { Name = each.value }
}
