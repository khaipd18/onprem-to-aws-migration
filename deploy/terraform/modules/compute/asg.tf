data "aws_region" "current" {}

locals {
  instance_tags = merge(var.propagated_tags, {
    Name = "${var.name_prefix}-app"
    Tier = "app"
  })
}

resource "aws_launch_template" "app" {
  name          = "${var.name_prefix}-app"
  image_id      = data.aws_ssm_parameter.ami.value
  instance_type = var.instance_type

  vpc_security_group_ids = [var.app_security_group_id]

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    region                     = data.aws_region.current.region
    name_prefix                = var.name_prefix
    tier                       = "app"
    artifact_bucket            = aws_s3_bucket.artifacts.id
    queue_url                  = var.queue_url
    dlq_url                    = var.dlq_url
    accept_store_driver        = var.accept_store_driver
    accept_store_name          = var.accept_store_name
    visibility_timeout_seconds = var.visibility_timeout_seconds
    max_receive_count          = var.max_receive_count
    app_port                   = var.app_port
    allowed_origins            = var.allowed_origins
    colocate_worker            = "true"
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  tags = { Name = "${var.name_prefix}-app" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.name_prefix}-app"
  vpc_zone_identifier = var.private_subnet_ids

  min_size         = var.min_size
  desired_capacity = var.desired_capacity
  max_size         = var.max_size

  health_check_type         = "ELB"
  health_check_grace_period = 120
  default_instance_warmup   = 90

  target_group_arns = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  availability_zone_distribution {
    capacity_distribution_strategy = "balanced-best-effort"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  warm_pool {
    pool_state                  = "Stopped"
    min_size                    = var.warm_pool_size
    max_group_prepared_capacity = var.max_size

    instance_reuse_policy {
      reuse_on_scale_in = true
    }
  }

  dynamic "tag" {
    for_each = local.instance_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "app_requests" {
  name                   = "${var.name_prefix}-app-requests"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = var.requests_per_target

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.public.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}
