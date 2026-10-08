# The context is a literal on purpose (not a variable): this environment can only ever talk to the kind
# cluster named "usageline", whatever other contexts exist in the kubeconfig. If that context is missing,
# the providers fail instead of falling back to the current context.
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "kind-usageline"
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = "kind-usageline"
  }
}
