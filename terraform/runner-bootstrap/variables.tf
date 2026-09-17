variable "aws_region" {
  description = "Region for the runner instance. Must be the same region the CI workflows use (AWS_REGION repo variable), because the runner's EC2 permissions are region-conditioned."
  type        = string
}

variable "name" {
  description = "Name tag for the runner instance."
  type        = string
  default     = "github-runner-teleport-ci"
}

variable "vpc_id" {
  description = "VPC for the runner."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the runner. Either a private subnet with a NAT gateway, or a public subnet -- either way there are no inbound rules. Administrative access is via SSM Session Manager, not SSH."
  type        = string
}

variable "assign_public_ip" {
  description = "Set true only when subnet_id is a public subnet without NAT. The security group still allows no inbound traffic."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "Runner instance type. 2 vCPU / 2 GiB is enough for Helm plus Terraform."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root volume size in GiB. The runner is persistent and accumulates workspaces and Helm/Terraform caches."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# What the runner is allowed to touch. These must match the repository variables
# the workflows use, or the workflows will fail with AccessDenied.
# ---------------------------------------------------------------------------

variable "tf_state_bucket" {
  description = "S3 bucket holding Terraform state (repo variable TF_STATE_BUCKET). Versioning must be enabled."
  type        = string
}

variable "tf_state_prefix" {
  description = "Key prefix inside tf_state_bucket that the runner may read and write."
  type        = string
  default     = "teleport-ci/"
}

variable "route53_zone_id" {
  description = "Hosted zone the runner may change records in (repo variable ROUTE53_ZONE_ID)."
  type        = string
}

variable "agent_iam_path" {
  description = "IAM path the runner may create roles and instance profiles under. Must match var.iam_path in terraform/ec2-agent. This path scoping is what keeps the runner's iam:* grant from being a privilege-escalation path (SPEC.md §7.2)."
  type        = string
  default     = "/teleport-ci/"

  validation {
    condition     = can(regex("^/.+/$", var.agent_iam_path))
    error_message = "agent_iam_path must start and end with a slash and must not be the root path."
  }
}

variable "managed_by_tag_value" {
  description = "Value of the ManagedBy tag that mutating EC2 actions are conditioned on."
  type        = string
  default     = "github-actions"
}

# ---------------------------------------------------------------------------
# Runner registration.
# ---------------------------------------------------------------------------

variable "github_owner" {
  description = "GitHub org or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name (without the owner)."
  type        = string
}

variable "runner_label" {
  description = "Extra label for the runner (repo variable RUNNER_LABEL). Workflows select [self-hosted, linux, x64, <this>]."
  type        = string
  default     = "teleport-ci"
}

variable "runner_version" {
  description = "actions/runner release to install, without the leading v."
  type        = string
  default     = "2.322.0"
}

variable "runner_credential_source" {
  description = <<-EOT
    How the runner mints a registration token at boot.

      github_app  RECOMMENDED. Reads a GitHub App private key from SSM Parameter
                  Store, signs a JWT, exchanges it for an installation token, and
                  asks GitHub for a short-lived registration token. Nothing
                  long-lived and broadly-scoped sits on the instance.
      pat         Weaker fallback. Reads a classic PAT (scope: repo) from SSM and
                  uses it directly. A PAT is long-lived and, unlike an App
                  installation, is bound to a human account -- prefer github_app.
  EOT
  type        = string
  default     = "github_app"

  validation {
    condition     = contains(["github_app", "pat"], var.runner_credential_source)
    error_message = "runner_credential_source must be github_app or pat."
  }
}

variable "github_app_id" {
  description = "GitHub App ID. Required when runner_credential_source = github_app."
  type        = string
  default     = ""
}

variable "github_app_installation_id" {
  description = "Installation ID of the App on the repository. Required when runner_credential_source = github_app."
  type        = string
  default     = ""
}

variable "credential_ssm_parameter" {
  description = "Name of the SSM Parameter Store SecureString holding either the GitHub App PEM private key or the PAT. Created out of band by the operator (see docs/bootstrap.md) -- deliberately NOT managed by Terraform, so the secret never enters Terraform state."
  type        = string
}

variable "teleport_version" {
  description = "Teleport version whose client tools (tsh/tctl) are installed on the runner for manual debugging. Should equal the TELEPORT_VERSION repo variable."
  type        = string
  default     = "18.11.1"
}

variable "install_teleport_tools" {
  description = "Install tsh/tctl on the runner. Optional: tctl in CI runs inside the auth pod (scripts/tctl.sh), so this is only for interactive debugging over SSM."
  type        = bool
  default     = true
}
