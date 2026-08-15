output "vpc_id" {
  description = "ID of the VPC this stack created."
  value       = module.network.vpc_id
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer; the prober's target when running against AWS."
  value       = module.compute.alb_dns_name
}

output "ecr_repository_url" {
  description = "ECR repository the pipeline pushes application images to."
  value       = module.registry.repository_url
}

output "autoscaling_group_name" {
  description = "Name of the application auto scaling group, used by Ansible's dynamic inventory."
  value       = module.compute.autoscaling_group_name
}
