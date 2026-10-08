# Second line of defence behind the hard-coded context: refuse to run unless every node of the cluster we are
# connected to is a kind node of the "usageline" cluster.
data "kubernetes_nodes" "this" {}

resource "terraform_data" "cluster_guard" {
  lifecycle {
    precondition {
      condition = length(data.kubernetes_nodes.this.nodes) > 0 && alltrue([
        for node in data.kubernetes_nodes.this.nodes : startswith(node.metadata.name, "usageline-")
      ])
      error_message = "Connected cluster does not look like the kind cluster 'usageline' (node names must start with 'usageline-'). Refusing to continue."
    }
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [terraform_data.cluster_guard]
}

resource "kubernetes_namespace_v1" "usageline" {
  metadata {
    name = "usageline"
  }

  depends_on = [terraform_data.cluster_guard]
}

# Installs the Prometheus Operator CRDs that the usageline chart's ServiceMonitor/PrometheusRule need.
resource "helm_release" "kube_prometheus_stack" {
  name       = "kps"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  values  = [file("${path.module}/../../../monitoring/values.yaml")]
  timeout = 600
  wait    = true
}

resource "helm_release" "usageline" {
  name      = "usageline"
  namespace = kubernetes_namespace_v1.usageline.metadata[0].name
  chart     = "${path.module}/../../../helm/usageline"

  values = [file("${path.module}/../../../monitoring/usageline-values.yaml")]

  set = [
    {
      name  = "image.tag"
      value = var.image_tag
    },
    {
      name  = "hpa.maxReplicas"
      value = tostring(var.hpa_max_replicas)
    },
  ]

  timeout = 300
  wait    = true

  depends_on = [helm_release.kube_prometheus_stack]
}
