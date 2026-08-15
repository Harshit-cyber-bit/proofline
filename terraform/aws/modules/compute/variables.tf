variable "name" {
  description = "Name prefix for compute resources."
  type        = string
}

variable "environment" {
  description = "Environment name, used in resource names and tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC to place the load balancer and instances in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets for the application instances."
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type for the fleet."
  type        = string
}

variable "min_size" {
  description = "Minimum instances in the auto scaling group."
  type        = number
}

variable "max_size" {
  description = "Maximum instances in the auto scaling group."
  type        = number
}

variable "app_port" {
  description = "Port the application listens on."
  type        = number
}

variable "health_check_path" {
  description = "Path the load balancer probes. Points at readiness, not liveness, so a draining instance leaves the target group promptly."
  type        = string
  default     = "/readyz"
}

variable "deregistration_delay" {
  description = "Seconds the load balancer keeps draining a removed target. Must exceed the application's own drain window or in-flight requests are cut."
  type        = number
  default     = 30
}
