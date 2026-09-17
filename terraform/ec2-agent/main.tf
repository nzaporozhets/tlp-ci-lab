# A single EC2 node running a Teleport SSH agent that joins the cluster with the
# `iam` join method.
#
# Deliberate properties (SPEC.md §6.1, §10.2):
#   * The instance role has NO policies attached. Its only purpose is to give the
#     instance an assumed-role ARN that the provision token can match.
#   * The security group has NO inbound rules and there is NO key pair. The node
#     is reachable only through Teleport -- that is the point of the exercise.
#   * IMDSv2 is required, which is also what makes the `iam` join method's
#     credential lookup work sanely.

locals {
  sentinel_path = "/var/lib/teleport-bootstrap/complete"

  tags = merge(
    {
      Name      = var.name
      ManagedBy = "github-actions"
    },
    var.github_run_url == "" ? {} : { GitHubRunURL = var.github_run_url },
  )
}

# Latest Amazon Linux 2023 AMI, via the AWS-published SSM public parameter. This
# avoids an ec2:DescribeImages filter and is the documented lookup.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "agent_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# No-op role: no aws_iam_role_policy, no inline policy, and (by default) no
# managed policy attachments.
resource "aws_iam_role" "agent" {
  name                 = var.role_name
  path                 = var.iam_path
  assume_role_policy   = data.aws_iam_policy_document.agent_assume_role.json
  max_session_duration = 3600
  description          = "No-op role for the teleport-ci EC2 agent. Exists only so the instance has an ARN the Teleport iam-join token can match."

  tags = local.tags
}

# Opt-in only; see the variable description for why this is off by default.
resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.attach_ssm_policy ? 1 : 0
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "agent" {
  name = var.role_name
  path = var.iam_path
  role = aws_iam_role.agent.name

  tags = local.tags
}

resource "aws_security_group" "agent" {
  name_prefix = "${var.name}-"
  description = "Teleport CI agent: egress only. No inbound rules by design."
  vpc_id      = var.vpc_id

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Intentionally: no ingress rules at all.
resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.agent.id
  description       = "Outbound to the Teleport proxy, STS, and package repositories"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = local.tags
}

resource "aws_instance" "agent" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = [aws_security_group.agent.id]
  iam_instance_profile   = aws_iam_instance_profile.agent.name

  # No key_name: SSH access is via Teleport only.

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  monitoring = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
    tags                  = local.tags
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    teleport_version = var.teleport_version
    proxy_addr       = var.proxy_addr
    token_name       = var.join_token_name
    sentinel_path    = local.sentinel_path
    # Rendered into teleport.yaml as `key: "value"` lines.
    teleport_labels = var.teleport_labels
  })

  tags = local.tags

  # The AMI ID changes whenever AWS publishes a new AL2023 build. Ignoring it
  # keeps re-runs of deploy.yml a genuine no-op (acceptance criterion 3); rebuild
  # the node deliberately with `terraform taint` or by bumping teleport_version.
  lifecycle {
    ignore_changes = [ami]
  }
}
