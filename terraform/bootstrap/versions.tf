terraform {
  required_version = ">= 1.10"

  # Deliberately no remote backend: this folder creates the bucket the other folders store state in,
  # so its own (tiny) state stays local. Do not commit terraform.tfstate if you apply it.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "usageline"
      ManagedBy = "terraform"
      Component = "state-bootstrap"
    }
  }
}
