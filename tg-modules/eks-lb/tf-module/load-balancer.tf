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

# ALB Target Group and Autoscaling Attachment
resource "aws_autoscaling_attachment" "asg_attachment_alb" {
  for_each = var.load_balancer_type == "application" ? var.autoscale_group_names : toset([])

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.alb_main[0].arn
}

# NLB Target Group and Autoscaling Attachment for RTMP
resource "aws_autoscaling_attachment" "asg_attachment_nlb_rtmp" {
  for_each = var.load_balancer_type == "network" && var.enable_rtmp ? var.autoscale_group_names : toset([])

  autoscaling_group_name = each.value
  lb_target_group_arn    = aws_lb_target_group.nlb_rtmp[0].arn
}

# ALB Target Group
resource "aws_lb_target_group" "alb_main" {
  count = var.load_balancer_type == "application" ? 1 : 0

  name_prefix = local.lb_name_prefix
  port        = var.node_port
  protocol    = var.node_port_protocol
  target_type = var.target_type
  vpc_id      = var.vpcid

  health_check {
    port                = var.health_check_port_alb
    protocol            = var.health_check_protocol_alb
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 6
    path                = var.health_check_path
    matcher             = var.health_check_matcher
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
    Name = "${var.cluster_name}-alb"
  }
}

# NLB Target Group for RTMP
resource "aws_lb_target_group" "nlb_rtmp" {
  count = var.load_balancer_type == "network" && var.enable_rtmp ? 1 : 0

  name_prefix = local.lb_name_prefix
  port        = var.rtmp_node_port  # Target the NodePort, not the service port
  protocol    = "TCP"
  target_type = var.target_type
  vpc_id      = var.vpcid

  health_check {
    port                = "traffic-port"
    protocol            = "TCP"
    interval            = var.health_check_interval_nlb
    healthy_threshold   = var.healthy_threshold_nlb
    unhealthy_threshold = var.unhealthy_threshold_nlb
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-nlb-rtmp"
  }
}

# ALB Listeners
resource "aws_lb_listener" "alb_http_forward" {
  count = var.load_balancer_type == "application" && var.enable_http && var.http_redirect == false ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_main[0].arn
  }
}

resource "aws_lb_listener" "alb_http_redirect" {
  count = var.load_balancer_type == "application" && var.enable_https && var.http_redirect ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = var.https_port
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "alb_https" {
  count = var.load_balancer_type == "application" && var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = var.https_port
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_main[0].arn
  }
}

# NLB Listeners
resource "aws_lb_listener" "nlb_rtmp" {
  count = var.load_balancer_type == "network" && var.enable_rtmp ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = var.rtmp_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_rtmp[0].arn
  }
}
