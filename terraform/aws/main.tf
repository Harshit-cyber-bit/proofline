# A real AWS reference stack. CI validates and parses it; nothing applies it
# automatically, because applying it costs money.
#
# Shape: a VPC across N availability zones, a public ALB, a private auto scaling
# group of application instances, and an ECR repository. It is deliberately the
# same topology the local Docker stack imitates, so the Ansible playbooks and
# the deployment story carry over unchanged.
#
# Rough cost if you do apply it, ap-south-1, on-demand, single NAT:
#   ALB ~$18/mo + NAT ~$32/mo + 2x t3.small ~$30/mo  =>  about $80/mo.
# Run `make aws-destroy` when you are done. The reason that target exists is
# that forgetting is the normal outcome.

locals {
  tags = {
    Project     = var.name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "proofline"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "network" {
  source = "./modules/network"

  name               = var.name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)
  single_nat_gateway = var.single_nat_gateway
}

module "registry" {
  source = "./modules/registry"

  name        = var.name
  environment = var.environment
}

module "compute" {
  source = "./modules/compute"

  name              = var.name
  environment       = var.environment
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  instance_type     = var.instance_type
  min_size          = var.fleet_min_size
  max_size          = var.fleet_max_size
  app_port          = var.app_port
}
