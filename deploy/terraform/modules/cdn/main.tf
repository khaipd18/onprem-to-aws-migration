locals {
  alb_origin_id    = "${var.name_prefix}-alb"
  assets_origin_id = "${var.name_prefix}-assets"

  caching_optimized_policy_id         = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  caching_disabled_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  all_viewer_except_host_header_id    = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  cors_s3_origin_request_policy_id    = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
  security_headers_response_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"
}

resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${var.name_prefix}-assets"
  description                       = "Lets the distribution read the asset bucket without making it public"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name_prefix} entry point"
  price_class         = var.price_class
  http_version        = "http2and3"
  default_root_object = "index.html"

  origin {
    origin_id   = local.alb_origin_id
    domain_name = var.alb_domain_name

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = var.origin_protocol_policy
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 60
      origin_read_timeout      = 30
    }
  }

  origin {
    origin_id                = local.assets_origin_id
    domain_name              = var.assets_bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  default_cache_behavior {
    target_origin_id       = local.assets_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = local.caching_optimized_policy_id
    origin_request_policy_id   = local.cors_s3_origin_request_policy_id
    response_headers_policy_id = local.security_headers_response_policy_id
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = local.alb_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = local.caching_disabled_policy_id
    origin_request_policy_id   = local.all_viewer_except_host_header_id
    response_headers_policy_id = local.security_headers_response_policy_id
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }

  tags = { Name = "${var.name_prefix}-cdn" }

  lifecycle {
    precondition {
      condition     = var.alb_domain_name != ""
      error_message = "alb_domain_name is required. The distribution needs an origin for the API calls the page makes."
    }
  }
}

data "aws_iam_policy_document" "assets" {
  statement {
    sid     = "AllowCloudFrontRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    resources = ["${var.assets_bucket_arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = var.assets_bucket_id
  policy = data.aws_iam_policy_document.assets.json
}
