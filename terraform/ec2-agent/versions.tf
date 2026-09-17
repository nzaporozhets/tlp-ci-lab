terraform {
  # >= 1.10 is required for S3 backend native locking (`use_lockfile`), which is
  # what lets us drop the DynamoDB lock table. See backend.tf.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.82"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "github-actions"
      Project   = "teleport-ci"
    }
  }
}
