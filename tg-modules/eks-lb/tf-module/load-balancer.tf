# Main Load Balancer (ALB or NLB)
resource "aws_lb" "main" {
  name               = format("%s-%s", local.short_cluster_name, local.random_id)
  internal           = var.internal
  load_balancer_type = var.load_balancer_type

  # Security groups only for ALB
  security_groups = var.load_balancer_type == "application" ? [aws_security_group.main[0].id] : null

  subnets = var.subnet_ids_list

  # ALB specific settings
  preserve_host_header       = var.load_balancer_type == "application" ? true : null
  drop_invalid_header_fields = var.load_balancer_type == "application" ? true : null

  # NLB specific settings
  enable_cross_zone_load_balancing = var.load_balancer_type == "network" ? var.enable_cross_zone_load_balancing : null

  tags = merge({
    "ingress.k8s.aws/resource" = "LoadBalancer"
    "ingress.k8s.aws/cluster"  = var.cluster_name
  }, var.tags)
}

# Dynamic ALB Autoscaling Attachments
resource "aws_autoscaling_attachment" "asg_attachment_alb" {
  for_each = var.load_balancer_type == "application" ? {
    for combo in setproduct(keys(var.alb_listeners), var.autoscale_group_names) :
    "${combo[0]}-${combo[1]}" => {
      target_group_key = combo[0]
      asg_name        = combo[1]
    }
  } : {}

  autoscaling_group_name = each.value.asg_name
  lb_target_group_arn    = aws_lb_target_group.alb_target_groups[each.value.target_group_key].arn
}

# Dynamic NLB Autoscaling Attachments
resource "aws_autoscaling_attachment" "asg_attachment_nlb" {
  for_each = var.load_balancer_type == "network" ? {
    for combo in setproduct(keys(var.nlb_target_groups), var.autoscale_group_names) :
    "${combo[0]}-${combo[1]}" => {
      target_group_key = combo[0]
      asg_name        = combo[1]
    }
  } : {}

  autoscaling_group_name = each.value.asg_name
  lb_target_group_arn    = aws_lb_target_group.nlb_target_groups[each.value.target_group_key].arn
}

# Dynamic ALB Target Groups
resource "aws_lb_target_group" "alb_target_groups" {
  for_each = var.load_balancer_type == "application" ? var.alb_listeners : {}

  name_prefix = local.lb_name_prefix
  port        = each.value.target_port
  protocol    = each.value.target_protocol
  target_type = var.target_type
  vpc_id      = var.vpcid

  health_check {
    port                = each.value.health_check.port
    protocol            = each.value.health_check.protocol
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 6
    path                = each.value.health_check.path
    matcher             = each.value.health_check.matcher
  }

  stickiness {
    type            = var.stickiness_type
    enabled         = var.stickiness_enabled
    cookie_duration = var.stickiness_cookie_duration
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-alb-${each.key}"
  }
}

# Dynamic Target Groups for NLB based on configuration
resource "aws_lb_target_group" "nlb_target_groups" {
  for_each = var.load_balancer_type == "network" ? var.nlb_target_groups : {}

  name_prefix = local.lb_name_prefix
  port        = each.value.target_port
  protocol    = each.value.target_protocol
  target_type = var.target_type
  vpc_id      = var.vpcid

  health_check {
    port                = each.value.health_check.port
    protocol            = each.value.health_check.protocol
    interval            = try(each.value.health_check.interval, var.health_check_interval_nlb)
    healthy_threshold   = try(each.value.health_check.healthy_threshold, var.healthy_threshold_nlb)
    unhealthy_threshold = try(each.value.health_check.unhealthy_threshold, var.unhealthy_threshold_nlb)
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-nlb-${each.key}"
  }
}

# Dynamic ALB Listeners
resource "aws_lb_listener" "alb_listeners" {
  for_each = var.load_balancer_type == "application" ? var.alb_listeners : {}

  load_balancer_arn = aws_lb.main.arn
  port              = each.value.listener_port
  protocol          = each.value.listener_protocol
  ssl_policy        = each.value.listener_protocol == "HTTPS" ? var.ssl_policy : null
  certificate_arn   = each.value.listener_protocol == "HTTPS" ? var.certificate_arn : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target_groups[each.key].arn
  }
}

# Dynamic NLB Listeners
resource "aws_lb_listener" "nlb_listeners" {
  for_each = var.load_balancer_type == "network" ? var.nlb_target_groups : {}

  load_balancer_arn = aws_lb.main.arn
  port              = each.value.listener_port
  protocol          = each.value.listener_protocol

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_target_groups[each.key].arn
  }
}
