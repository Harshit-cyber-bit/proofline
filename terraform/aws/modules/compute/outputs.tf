output "alb_dns_name" {
  description = "Public DNS name of the load balancer."
  value       = aws_lb.this.dns_name
}

output "autoscaling_group_name" {
  description = "Name of the application auto scaling group."
  value       = aws_autoscaling_group.this.name
}

output "app_security_group_id" {
  description = "Security group attached to application instances."
  value       = aws_security_group.app.id
}
