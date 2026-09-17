terraform {
  # Partial backend configuration: `bucket` and `region` are supplied at init
  # time from repository variables, so nothing environment-specific is committed:
  #
  #   terraform init -input=false \
  #     -backend-config="bucket=$TF_STATE_BUCKET" \
  #     -backend-config="region=$AWS_REGION"
  #
  # `use_lockfile = true` uses S3's native conditional-write locking (Terraform
  # >= 1.10). No DynamoDB table is needed. The bucket MUST have versioning
  # enabled -- deploy.yml's preflight job asserts that.
  backend "s3" {
    key          = "teleport-ci/ec2-agent.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
