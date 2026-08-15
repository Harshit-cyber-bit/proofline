variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-south-1"
}

variable "name" {
  description = "Name prefix for every resource in this stack."
  type        = string
  default     = "proofline"
}

variable "environment" {
  description = "Environment name, used in tags and resource names."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 leaves room to subnet per-AZ without renumbering later."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zone_count" {
  description = "How many AZs to spread subnets across. Two is the minimum for a load balancer; three is the minimum to survive an AZ failure with quorum intact."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the application fleet."
  type        = string
  default     = "t3.small"
}

variable "fleet_min_size" {
  description = "Minimum instances in the auto scaling group. Two so a rolling replacement never drops to a single host."
  type        = number
  default     = 2
}

variable "fleet_max_size" {
  description = "Maximum instances in the auto scaling group."
  type        = number
  default     = 6
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway across all AZs. Cheaper by roughly the cost of a NAT per AZ, at the cost of a single-AZ dependency. False for anything real."
  type        = bool
  default     = true
}

variable "app_port" {
  description = "Port the application listens on behind the load balancer."
  type        = number
  default     = 8080
}
