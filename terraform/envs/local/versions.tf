terraform {
  required_version = ">= 1.10"

  # No remote backend on purpose: this environment manages a throwaway local kind cluster, so its state is a
  # local terraform.tfstate (git-ignored). It can contain rendered chart values, so never commit it.

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}
