#
# Security group for Load Balancer (ALB only - NLB doesn't need security groups)
#

resource "aws_security_group" "main" {
  count = var.load_balancer_type == "application" ? 1 : 0

  name        = format("%s-%s", local.short_cluster_name, local.random_id)
  description = "ALB Security group for EKS cluster "
  vpc_id      = var.vpcid

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({
    Name = format("%s-%s", var.cluster_name, local.random_id)
  }, var.tags)
}

resource "aws_security_group_rule" "alb-to-nodes" {
  for_each = var.load_balancer_type == "application" ? var.cluster_security_group_ids : toset([])

  description              = "Allows users connect to apps through alb"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = each.value
  source_security_group_id = aws_security_group.main[0].id
  type                     = "ingress"
}

resource "aws_security_group_rule" "http-inbound" {
  count             = var.load_balancer_type == "application" && var.enable_http ? 1 : 0
  from_port         = var.http_port
  to_port           = var.http_port
  cidr_blocks       = [var.cidr_blocks]
  security_group_id = aws_security_group.main[0].id
  protocol          = "tcp"
  type              = "ingress"
}

resource "aws_security_group_rule" "https-inbound" {
  count             = var.load_balancer_type == "application" && var.enable_https ? 1 : 0
  from_port         = var.https_port
  to_port           = var.https_port
  cidr_blocks       = [var.cidr_blocks]
  security_group_id = aws_security_group.main[0].id
  protocol          = "tcp"
  type              = "ingress"
}
