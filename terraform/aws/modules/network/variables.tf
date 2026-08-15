variable "name" {
  description = "Name prefix for network resources."
  type        = string
}

variable "environment" {
  description = "Environment name, used in resource names and tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway across all AZs instead of one per AZ."
  type        = bool
  default     = true
}
