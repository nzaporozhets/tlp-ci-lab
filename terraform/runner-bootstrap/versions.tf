terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.82"
    }
  }

  # Deliberately no backend block: this module is applied ONCE, by hand, from the
  # operator's machine with credentials GitHub never sees (SPEC.md §7). State is
  # local -- keep terraform.tfstate somewhere durable and private, or add your own
  # backend block. Do not point it at the same bucket/key the CI module uses.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "teleport-ci"
      ManagedBy = "terraform-runner-bootstrap"
    }
  }
}
