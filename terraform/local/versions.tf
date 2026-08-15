terraform {
  required_version = ">= 1.6.0"

  # Every provider pinned to a minor line. An unpinned provider means the plan
  # reviewed today and the plan applied next month are different plans, and the
  # difference surfaces at apply time.
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "docker" {}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}
