# The local stack: a small server fleet for Ansible to configure, and the
# monitoring stack the pipeline's SLO gate queries.
#
# The kind cluster itself is created by the Makefile rather than by Terraform.
# The community kind providers wrap a CLI that is not designed to be a
# Terraform resource, and a half-created cluster in state is far more annoying
# than one shell command. Terraform manages what it manages well.

locals {
  common_labels = {
    "proofline.managed" = "true"
    "proofline.stack"   = "local"
  }
}

resource "docker_image" "fleet" {
  name         = var.fleet_image
  keep_locally = true
}

# The fleet Ansible configures. Containers rather than VMs because this has to
# run for free on a laptop; from Ansible's point of view they are hosts, and the
# playbooks are the same ones that would target EC2.
resource "docker_container" "fleet" {
  count = var.fleet_size

  name  = "${var.name_prefix}-app-${count.index + 1}"
  image = docker_image.fleet.image_id

  # Boot systemd as PID 1 so the Ansible roles can manage real systemd units.
  # The alternative -- `sleep infinity` and a nohup'd process -- would mean the
  # playbooks only work on containers, which defeats the point of writing them.
  command = ["/lib/systemd/systemd"]

  # systemd in a container needs both of these. This is a local demo fleet on a
  # throwaway kind cluster, not a pattern to copy into production.
  privileged = true

  volumes {
    host_path      = "/sys/fs/cgroup"
    container_path = "/sys/fs/cgroup"
    read_only      = false
  }

  must_run = true
  restart  = "unless-stopped"

  labels {
    label = "proofline.role"
    value = "app"
  }

  labels {
    label = "proofline.index"
    value = tostring(count.index + 1)
  }

  dynamic "labels" {
    for_each = local.common_labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# Monitoring. The pipeline queries Prometheus to decide whether a deployment
# earned its promotion, so this is part of the delivery path, not a side quest.
resource "helm_release" "monitoring" {
  count = var.monitoring_enabled ? 1 : 0

  name             = "monitoring"
  namespace        = "monitoring"
  create_namespace = true

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.monitoring_chart_version

  # A laptop cluster cannot carry the chart's defaults.
  values = [yamlencode({
    grafana = {
      adminPassword = "proofline"
      service = {
        type = "NodePort"
        nodePort = 30300
      }
    }
    prometheus = {
      service = {
        type     = "NodePort"
        nodePort = 30090
      }
      prometheusSpec = {
        retention = "6h"
        resources = {
          requests = { cpu = "100m", memory = "512Mi" }
          limits   = { cpu = "1", memory = "2Gi" }
        }
        # Pick up the ServiceMonitors and PrometheusRules this repo ships
        # without needing a release-name label on each of them.
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
      }
    }
    alertmanager = {
      service = {
        type     = "NodePort"
        nodePort = 30903
      }
    }
    # Neither is reachable inside kind's control-plane container, and both fail
    # loudly enough to look like a real problem.
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
  })]

  timeout = 900
  wait    = true
}
