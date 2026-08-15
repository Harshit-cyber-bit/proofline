variable "fleet_size" {
  description = "Number of application servers to provision. Represents the heterogeneous fleet that Ansible configures; three is enough to prove the playbooks are idempotent across hosts."
  type        = number
  default     = 3

  validation {
    condition     = var.fleet_size >= 1 && var.fleet_size <= 10
    error_message = "fleet_size must be between 1 and 10; this runs on a laptop."
  }
}

variable "fleet_image" {
  description = "Base image for the fleet servers. A systemd-enabled image, so the Ansible roles can use real systemd units and therefore work unchanged against EC2 -- this is the same pattern Molecule uses to test roles in containers."
  type        = string
  default     = "geerlingguy/docker-ubuntu2204-ansible:latest"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name, so a stray container is obviously ours."
  type        = string
  default     = "proofline"
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig holding the kind cluster context."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context for the local kind cluster."
  type        = string
  default     = "kind-proofline"
}

variable "monitoring_enabled" {
  description = "Install kube-prometheus-stack. Turn off on a constrained laptop; the pipeline's SLO gate is skipped when it is absent rather than failing."
  type        = bool
  default     = true
}

variable "monitoring_chart_version" {
  description = "Pinned kube-prometheus-stack chart version, so a rebuilt environment is the same environment."
  type        = string
  default     = "65.1.1"
}
