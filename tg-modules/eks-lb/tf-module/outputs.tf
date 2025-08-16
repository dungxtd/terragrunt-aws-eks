output "dns_name" {
  value = aws_lb.main.dns_name
}

output "zone_id" {
  value = aws_lb.main.zone_id
}

output "lb_arn" {
  value = aws_lb.main.arn
}

# Keep ALB output for backward compatibility
output "alb_arn" {
  value = aws_lb.main.arn
}

# NLB specific outputs
output "nlb_arn" {
  value = var.load_balancer_type == "network" ? aws_lb.main.arn : null
}

output "nlb_dns_name" {
  value = var.load_balancer_type == "network" ? aws_lb.main.dns_name : null
}

output "nlb_zone_id" {
  value = var.load_balancer_type == "network" ? aws_lb.main.zone_id : null
}
