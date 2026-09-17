variable "aws_region" {
  description = "AWS region for the agent instance."
  type        = string
}

variable "teleport_version" {
  description = "Teleport version to install on the node. Must equal the Helm chart version used for the cluster so the agent is never newer than the Auth Service (SPEC.md §9.4)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.teleport_version))
    error_message = "teleport_version must be an exact x.y.z version, not a range or a tag."
  }
}

variable "proxy_addr" {
  description = "Teleport proxy address the agent dials, host:port (e.g. teleport.ci.example.com:443). Passed through from the cluster job's output."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9.-]+:[0-9]+$", var.proxy_addr))
    error_message = "proxy_addr must be host:port."
  }
}

variable "join_token_name" {
  description = "Name of the Teleport provision token to join with. Not a secret: the `iam` join method has no shared secret (SPEC.md §3.1)."
  type        = string
  default     = "ec2-agent-token"
}

variable "role_name" {
  description = "Name of the no-op IAM role given to the agent instance. Must match EC2_AGENT_ROLE_NAME in deploy.yml, because teleport/tokens/ec2-agent-token.yaml pins the allowed assumed-role ARN to it."
  type        = string
  default     = "teleport-ci-ec2-agent"
}

variable "iam_path" {
  description = "IAM path for the agent role and instance profile. The runner's IAM permissions are scoped to this path (SPEC.md §7.2), so changing it here without changing the runner policy breaks the deploy."
  type        = string
  default     = "/teleport-ci/"

  validation {
    condition     = can(regex("^/.*/$", var.iam_path))
    error_message = "iam_path must start and end with a slash."
  }
}

variable "name" {
  description = "Name tag / hostname prefix for the agent instance."
  type        = string
  default     = "teleport-ci-agent"
}

variable "instance_type" {
  description = "EC2 instance type for the agent."
  type        = string
  default     = "t3.micro"
}

variable "subnet_id" {
  description = "Subnet for the agent. Needs outbound internet access to reach the Teleport proxy, STS, and the package repositories."
  type        = string
}

variable "vpc_id" {
  description = "VPC containing subnet_id; used for the agent security group."
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "github_run_url" {
  description = "URL of the GitHub Actions run that last applied this module, recorded as a tag for auditability."
  type        = string
  default     = ""
}

variable "teleport_labels" {
  description = "Static Teleport SSH labels for the node. `managed-by` is asserted by scripts/verify.sh, so keep it."
  type        = map(string)
  default = {
    env          = "ci"
    "managed-by" = "github-actions"
  }
}

variable "attach_ssm_policy" {
  description = <<-EOT
    Attach AmazonSSMManagedInstanceCore to the agent role so the failure-dump step
    can pull cloud-init / Teleport logs with `aws ssm send-command`.

    Default false, deliberately. SPEC.md §6.1 and §10.2 require this role to be a
    no-op role, and SPEC.md §7.2 deliberately withholds iam:AttachRolePolicy from
    the runner -- so setting this to true makes `terraform apply` fail with
    AccessDenied when run from the CI runner. Enable it only if you also widen the
    runner policy (see docs/bootstrap.md, "SSM on the agent node"), and accept
    that the agent role is then no longer a no-op role.

    Without it, failure diagnostics fall back to `ec2:GetConsoleOutput`, which the
    runner role does grant.
  EOT
  type        = bool
  default     = false
}
