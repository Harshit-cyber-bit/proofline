terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Remote state, commented rather than deleted. Local state is fine for a
  # reference stack one person applies; it stops being fine the moment a second
  # person or a pipeline runs it, and the fix belongs in the repo where whoever
  # hits that can find it.
  #
  # backend "s3" {
  #   bucket       = "proofline-tfstate"
  #   key          = "aws/terraform.tfstate"
  #   region       = "ap-south-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
